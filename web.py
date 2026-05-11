#!/usr/bin/env python3
"""
Flask web UI for Trafikverket körkortsprov checker.

Server-side scanning with BankID authentication.
The server maintains an authenticated session with Trafikverket and
scans for available driving test times.
"""

import json
import os
import uuid
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timedelta, timezone
from pathlib import Path

import requests as http_requests
from flask import (
    Flask, redirect, render_template, request, jsonify, session, url_for,
)

app = Flask(__name__)
# Secret key for session cookies. Generate with: python -c "import secrets; print(secrets.token_hex(32))"
app.secret_key = os.environ.get("SECRET_KEY") or os.urandom(32)
app.config.update(
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE="Lax",
    # Secure cookie when served over HTTPS (Fly.io sets X-Forwarded-Proto)
    SESSION_COOKIE_SECURE=os.environ.get("COOKIE_SECURE", "0") in ("1", "true", "True"),
)

PROJECT_DIR = Path(__file__).parent
# DATA_DIR can be overridden (e.g. mounted persistent volume on Fly.io).
# Read-only seed files (valid_locations.json, location_details.json) live in
# the bundled ./data folder; runtime state goes to DATA_DIR.
SEED_DATA_DIR = PROJECT_DIR / "data"
DATA_DIR = Path(os.environ.get("DATA_DIR", str(SEED_DATA_DIR)))
DATA_DIR.mkdir(parents=True, exist_ok=True)

CONFIG_PATH = Path(os.environ.get("CONFIG_PATH", str(DATA_DIR / "config.json")))
# Bootstrap config.json on the volume from the bundled one if missing.
if not CONFIG_PATH.exists() and (PROJECT_DIR / "config.json").exists():
    try:
        CONFIG_PATH.write_text((PROJECT_DIR / "config.json").read_text())
    except Exception:
        pass

LOCATIONS_PATH = SEED_DATA_DIR / "valid_locations.json"
LOCATION_DETAILS_PATH = SEED_DATA_DIR / "location_details.json"
SNAPSHOT_PATH = DATA_DIR / "last_snapshot.json"
RESERVATIONS_PATH = DATA_DIR / "reservations.json"
LOG_PATH = DATA_DIR / "activity_log.json"
SMS_NOTIFIED_PATH = DATA_DIR / "sms_notified.json"

# ── Login (form-based session auth; set LOGIN_USER + LOGIN_PASS env vars) ──
# Backwards compatible with the old BASIC_AUTH_USER / BASIC_AUTH_PASS names.
LOGIN_USER = os.environ.get("LOGIN_USER") or os.environ.get("BASIC_AUTH_USER", "")
LOGIN_PASS = os.environ.get("LOGIN_PASS") or os.environ.get("BASIC_AUTH_PASS", "")

# Endpoints that don't require login (the login page itself + static files).
_PUBLIC_ENDPOINTS = {"login", "static"}


@app.before_request
def _require_login():
    if not LOGIN_USER or not LOGIN_PASS:
        return None  # auth disabled
    if request.endpoint in _PUBLIC_ENDPOINTS:
        return None
    if session.get("user") == LOGIN_USER:
        return None
    # JSON / XHR clients get a 401 instead of a redirect
    if request.path.startswith("/api/") or \
       request.accept_mimetypes.best == "application/json" or \
       request.headers.get("X-Requested-With") == "XMLHttpRequest":
        return jsonify({"ok": False, "error": "login_required"}), 401
    return redirect(url_for("login", next=request.path))


@app.route("/login", methods=["GET", "POST"])
def login():
    # If auth is disabled, just bounce to the app
    if not LOGIN_USER or not LOGIN_PASS:
        return redirect(url_for("index"))
    error = None
    if request.method == "POST":
        username = (request.form.get("username") or "").strip()
        password = request.form.get("password") or ""
        if username == LOGIN_USER and password == LOGIN_PASS:
            session.clear()
            session["user"] = LOGIN_USER
            session.permanent = True
            nxt = request.args.get("next") or url_for("index")
            # Only allow same-site relative redirects
            if not nxt.startswith("/") or nxt.startswith("//"):
                nxt = url_for("index")
            return redirect(nxt)
        error = "Fel användarnamn eller lösenord"
    return render_template("login.html", error=error), (401 if error else 200)


@app.route("/logout", methods=["GET", "POST"])
def logout():
    session.clear()
    return redirect(url_for("login"))

SMS_NOTIFY_TTL_MINUTES = 30

# CA bundle resolution.
# Order of preference:
#   1. CA_BUNDLE env var (explicit override).
#   2. Project-local certs/ca-bundle.pem (built via scripts/build_ca_bundle.sh
#      to merge certifi + corporate roots like Zscaler/LF).
#   3. System bundle /etc/ssl/certs/ca-certificates.crt.
#   4. certifi default (True).
import ssl as _ssl
_PROJECT_CA = Path(__file__).parent / "certs" / "ca-bundle.pem"
_SYS_CA_BUNDLE = "/etc/ssl/certs/ca-certificates.crt"
_env_ca = os.environ.get("CA_BUNDLE")
if _env_ca and Path(_env_ca).exists():
    CA_BUNDLE = _env_ca
elif _PROJECT_CA.exists():
    CA_BUNDLE = str(_PROJECT_CA)
elif Path(_SYS_CA_BUNDLE).exists():
    CA_BUNDLE = _SYS_CA_BUNDLE
else:
    CA_BUNDLE = True


def _build_ssl_context():
    """Build an SSLContext that trusts our bundle and accepts any cert in
    the bundle as a trust anchor (VERIFY_X509_PARTIAL_CHAIN).

    This is required behind TLS-intercepting proxies (e.g. Zscaler) where
    the locally installed root cert may not match the actual root that
    signed the proxy's intermediate. With PARTIAL_CHAIN, including the
    proxy's intermediate in the bundle is sufficient.
    """
    cafile = CA_BUNDLE if isinstance(CA_BUNDLE, str) else None
    ctx = _ssl.create_default_context(cafile=cafile)
    if cafile is None:
        ctx.load_default_certs()
    try:
        ctx.verify_flags |= _ssl.VERIFY_X509_PARTIAL_CHAIN
    except AttributeError:
        pass
    return ctx


class _PartialChainAdapter(http_requests.adapters.HTTPAdapter):
    """requests adapter that uses our partial-chain SSLContext."""
    def init_poolmanager(self, *args, **kwargs):
        kwargs["ssl_context"] = _build_ssl_context()
        return super().init_poolmanager(*args, **kwargs)

    def proxy_manager_for(self, *args, **kwargs):
        kwargs["ssl_context"] = _build_ssl_context()
        return super().proxy_manager_for(*args, **kwargs)


def _outbound_session() -> "http_requests.Session":
    """Session for outbound notification calls (SMS, ntfy) with the
    partial-chain SSL context mounted for HTTPS."""
    s = http_requests.Session()
    s.mount("https://", _PartialChainAdapter())
    return s


_notify_session = _outbound_session()

RESERVATION_HOLD_MINUTES = 15
# NOTE: must be lowercase "boka". Trafikverket's edge has started returning 403
# (no body) for the uppercase "/Boka/check-authentication-status-qr" path while
# the lowercase variant still works. Use lowercase for all API calls.
TV_BASE = "https://fp.trafikverket.se/boka"
EXAM_TYPE_IDS = {"Körprov": 12, "Kunskapsprov": 3}
LICENCE_PARAMS = {
    "B": {"licence_id": 5, "vehicle_type_id": 2, "exam_ids": {"Körprov": 12, "Kunskapsprov": 3}},
    "A": {"licence_id": 4, "vehicle_type_id": 1, "exam_ids": {"Körprov": 10, "Kunskapsprov": 2}},
    "A1": {"licence_id": 2, "vehicle_type_id": 1, "exam_ids": {"Körprov": 10, "Kunskapsprov": 2}},
    "A2": {"licence_id": 24, "vehicle_type_id": 1, "exam_ids": {"Körprov": 10, "Kunskapsprov": 2}},
}

# ── Trafikverket session state (single user) ──
tv_session = http_requests.Session()
tv_session.headers.update({
    "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36",
    "X-Requested-With": "XMLHttpRequest",
    "Content-Type": "application/json; charset=utf-8",
    "Origin": "https://fp.trafikverket.se",
    "Referer": "https://fp.trafikverket.se/Boka/ng",
})
auth_state = {"referenceId": None, "qrStartToken": None, "qrStartTime": None,
              "qrStartSecret": None, "authenticated": False}
auth_lock = threading.Lock()


def _init_tv_session():
    """Hit the ng page to get session cookies (required for CSRF)."""
    try:
        tv_session.get(TV_BASE + "/ng", timeout=12)
    except Exception:
        pass


def load_config() -> dict:
    with open(CONFIG_PATH, "r") as f:
        return json.load(f)


def save_config_file(config: dict):
    with open(CONFIG_PATH, "w") as f:
        json.dump(config, f, indent=4, ensure_ascii=False)


def load_location_ids() -> dict:
    with open(LOCATIONS_PATH, "r") as f:
        return json.load(f)


def load_snapshot() -> list[dict]:
    if SNAPSHOT_PATH.exists():
        with open(SNAPSHOT_PATH, "r") as f:
            return json.load(f)
    return []


def save_snapshot(times: list[dict]):
    with open(SNAPSHOT_PATH, "w") as f:
        json.dump(times, f, indent=2, ensure_ascii=False)


def load_reservations() -> list[dict]:
    if RESERVATIONS_PATH.exists():
        with open(RESERVATIONS_PATH, "r") as f:
            return json.load(f)
    return []


def save_reservations(reservations: list[dict]):
    with open(RESERVATIONS_PATH, "w") as f:
        json.dump(reservations, f, indent=2, ensure_ascii=False)


def load_activity_log() -> list[dict]:
    if LOG_PATH.exists():
        with open(LOG_PATH, "r") as f:
            return json.load(f)
    return []


def save_activity_log(log: list[dict]):
    with open(LOG_PATH, "w") as f:
        json.dump(log[-200:], f, indent=2, ensure_ascii=False)


def make_key(t: dict) -> str:
    return f"{t.get('date','')}|{t.get('time','')}|{t.get('location','')}|{t.get('name','')}"


def load_sms_notified() -> dict:
    """Return {slot_key: iso_expiry} of recently SMS-notified slots, dropping expired."""
    if not SMS_NOTIFIED_PATH.exists():
        return {}
    try:
        with open(SMS_NOTIFIED_PATH, "r") as f:
            data = json.load(f)
    except Exception:
        return {}
    now_iso = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    return {k: v for k, v in data.items() if isinstance(v, str) and v > now_iso}


def save_sms_notified(notified: dict):
    with open(SMS_NOTIFIED_PATH, "w") as f:
        json.dump(notified, f, indent=2, ensure_ascii=False)


def send_sms(to: str, message: str, api_user: str, api_pass: str) -> dict:
    """Send an SMS via 46elks API."""
    try:
        r = _notify_session.post(
            "https://api.46elks.com/a1/sms",
            auth=(api_user, api_pass),
            data={"from": "Provbok", "to": to, "message": message},
            timeout=15,
            proxies={"http": None, "https": None},
            verify=CA_BUNDLE,
        )
        ok = r.status_code == 200
        app.logger.info("SMS to %s -> status=%s body=%s", to, r.status_code, r.text[:200])
        return {"ok": ok, "status": r.status_code, "data": r.text}
    except Exception as e:
        app.logger.error("SMS exception: %s", e)
        return {"ok": False, "error": str(e)}


def send_ntfy(topic: str, title: str, message: str, server: str = "https://ntfy.sh") -> dict:
    """Send a push notification via ntfy.sh (free, no account).

    Install the ntfy Windows app from https://ntfy.sh/ or open
    https://ntfy.sh/<topic> in a browser to receive notifications.
    """
    try:
        url = server.rstrip("/") + "/" + topic.strip().lstrip("/")
        r = _notify_session.post(
            url,
            data=message.encode("utf-8"),
            headers={
                "Title": title.encode("utf-8"),
                "Priority": "high",
                "Tags": "red_car,bell",
            },
            timeout=15,
            verify=CA_BUNDLE,
        )
        ok = 200 <= r.status_code < 300
        app.logger.info("ntfy to %s -> status=%s", topic, r.status_code)
        return {"ok": ok, "status": r.status_code, "data": r.text[:200]}
    except Exception as e:
        app.logger.error("ntfy exception: %s", e)
        return {"ok": False, "error": str(e)}


def _fetch_location(ssn: str, exam_type_id: int, location_id: int,
                    licence_id: int = 5, vehicle_type_id: int = 2) -> list[dict]:
    """Fetch available times for a single location using the authenticated session."""
    payload = {
        "bookingSession": {
            "socialSecurityNumber": ssn,
            "licenceId": licence_id,
            "bookingModeId": 0,
            "ignoreDebt": False,
            "ignoreBookingHindrance": False,
            "examinationTypeId": exam_type_id,
            "excludeExaminationCategories": [],
            "rescheduleTypeId": 0,
            "paymentIsActive": False,
            "paymentReference": None,
            "paymentUrl": None,
            "searchedMonths": 0,
        },
        "occasionBundleQuery": {
            "startDate": "1970-01-01T00:00:00.000Z",
            "searchedMonths": 0,
            "locationId": location_id,
            "nearbyLocationIds": [],
            "vehicleTypeId": vehicle_type_id,
            "tachographTypeId": 1,
            "occasionChoiceId": 1,
            "examinationTypeId": exam_type_id,
        },
    }
    try:
        r = tv_session.post(TV_BASE + "/occasion-bundles", json=payload, timeout=15)
        data = r.json()
        if data.get("status") == 200 and data.get("data", {}).get("bundles"):
            results = []
            for b in data["data"]["bundles"]:
                for o in b.get("occasions", []):
                    results.append({
                        "date": o.get("date", ""),
                        "time": o.get("time", ""),
                        "location": o.get("locationName", ""),
                        "location_id": o.get("locationId") or location_id,
                        "name": o.get("name", ""),
                        "cost": o.get("cost", ""),
                        "occasion_id": o.get("occasionId", ""),
                    })
            return results
    except Exception:
        pass
    return []


# ── Routes ──


@app.route("/")
def index():
    config = load_config()
    return render_template("index.html", config=config)


@app.route("/save_config", methods=["POST"])
def save_config_route():
    data = request.json
    config = load_config()
    config["swedish_ssn"] = data.get("swedish_ssn", "").strip()
    config["licence_type"] = data.get("licence_type", "B")
    config["exam_type"] = data.get("exam_type", "Körprov")
    locs = data.get("locations", "")
    if isinstance(locs, list):
        config["locations"] = [l.strip() for l in locs if l.strip()]
    else:
        config["locations"] = [l.strip() for l in locs.split(",") if l.strip()]
    config["date_from"] = data.get("date_from", "2026-04-13")
    config["date_to"] = data.get("date_to", "2026-12-31")
    config["sms_enabled"] = data.get("sms_enabled", False)
    config["sms_to"] = data.get("sms_to", "").strip()
    if "ntfy_enabled" in data:
        config["ntfy_enabled"] = bool(data.get("ntfy_enabled"))
    if "ntfy_topic" in data:
        config["ntfy_topic"] = data.get("ntfy_topic", "").strip()
    if "ntfy_server" in data:
        config["ntfy_server"] = (data.get("ntfy_server") or "https://ntfy.sh").strip()
    save_config_file(config)
    return jsonify({"status": "ok"})


# ── BankID Authentication ──


@app.route("/api/auth/check")
def auth_check():
    """Check if the Trafikverket session is authenticated."""
    if auth_state["authenticated"]:
        # Verify with Trafikverket that session is still valid
        try:
            r = tv_session.post(TV_BASE + "/is-authorizied", json=None, timeout=10)
            data = r.json()
            app.logger.info("is-authorizied: %s", data)
            if data.get("data") is True:
                return jsonify({"authenticated": True})
            else:
                auth_state["authenticated"] = False
        except Exception as e:
            app.logger.error("is-authorizied error: %s", e)
    return jsonify({"authenticated": auth_state["authenticated"]})


@app.route("/api/auth/begin", methods=["POST"])
def auth_begin():
    """Start BankID authentication. Returns QR code data."""
    with auth_lock:
        _init_tv_session()
        try:
            r = tv_session.post(TV_BASE + "/begin-authentication", json=None, timeout=15)
            data = r.json()
            if data.get("status") == 200 and data.get("data"):
                d = data["data"]
                auth_state["referenceId"] = d["referenceId"]
                auth_state["qrStartToken"] = d["qrStartToken"]
                auth_state["qrStartTime"] = d["qrStartTime"]
                auth_state["qrStartSecret"] = d["qrStartSecret"]
                auth_state["authenticated"] = False
                return jsonify({"ok": True, "qrCode": d["qrCode"],
                                "autostartToken": d["autostartToken"]})
            return jsonify({"ok": False, "error": data.get("data", {}).get("message", "Unknown error")})
        except Exception as e:
            return jsonify({"ok": False, "error": str(e)})


@app.route("/api/auth/status", methods=["POST"])
def auth_status():
    """Poll BankID authentication status. Returns updated QR code."""
    with auth_lock:
        if not auth_state["referenceId"]:
            return jsonify({"ok": False, "error": "No auth in progress"})
        payload = {
            "referenceId": auth_state["referenceId"],
            "qrStartToken": auth_state["qrStartToken"],
            "qrStartTime": auth_state["qrStartTime"],
            "qrStartSecret": auth_state["qrStartSecret"],
        }
    try:
        r = tv_session.post(TV_BASE + "/check-authentication-status-qr",
                            json=payload, timeout=15)
        if r.status_code == 403 or not r.text:
            app.logger.warning("Auth status got %s (empty body) - session may be invalid", r.status_code)
            return jsonify({"ok": False, "error": "Session expired, please restart login"})
        data = r.json()
        app.logger.info("Auth status raw: %s", data)
        d = data.get("data", {})
        status = d.get("collectionStatus", "")
        if status == "Completed":
            auth_state["authenticated"] = True
            auth_state["referenceId"] = None
            return jsonify({"ok": True, "status": "complete",
                            "loginStatus": d.get("loginStatus")})
        return jsonify({"ok": True, "status": status.lower() if status else "pending",
                        "qrCode": d.get("qrCode", "")})
    except Exception as e:
        app.logger.error("Auth status error: %s", e)
        return jsonify({"ok": False, "error": str(e)})


@app.route("/api/auth/set_test_user", methods=["POST"])
def auth_set_test_user():
    """Set test user SSN for the current auth session (dev/test only)."""
    data = request.json
    ssn = data.get("ssn", "")
    ref_id = auth_state.get("referenceId")
    if not ref_id:
        return jsonify({"ok": False, "error": "No auth in progress"})
    try:
        r = tv_session.post(TV_BASE + "/set-test-user",
                            json={"referenceId": ref_id, "socialSecurityNumber": ssn},
                            timeout=15)
        resp = r.json()
        if resp.get("status") == 200:
            auth_state["authenticated"] = True
            auth_state["referenceId"] = None
            return jsonify({"ok": True})
        return jsonify({"ok": False, "error": resp.get("data", {}).get("message", "")})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)})


@app.route("/api/auth/logout", methods=["POST"])
def auth_logout():
    """Sign out of the Trafikverket session."""
    global tv_session
    try:
        tv_session.post(TV_BASE + "/sign-out", json=None, timeout=10)
    except Exception:
        pass
    auth_state["authenticated"] = False
    auth_state["referenceId"] = None
    tv_session = http_requests.Session()
    tv_session.headers.update({
        "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36",
        "X-Requested-With": "XMLHttpRequest",
        "Content-Type": "application/json; charset=utf-8",
        "Origin": "https://fp.trafikverket.se",
        "Referer": "https://fp.trafikverket.se/Boka/ng",
    })
    return jsonify({"ok": True})


# ── Scanning ──


@app.route("/api/scan", methods=["POST"])
def api_scan():
    """Run a full scan of all configured locations. Returns times + changes."""
    if not auth_state["authenticated"]:
        return jsonify({"ok": False, "error": "Not authenticated"}), 401

    config = load_config()
    ssn = config.get("swedish_ssn", "")
    exam_type = config.get("exam_type", "Körprov")
    licence_type = config.get("licence_type", "B")
    lp = LICENCE_PARAMS.get(licence_type, LICENCE_PARAMS["B"])
    exam_type_id = lp["exam_ids"].get(exam_type, EXAM_TYPE_IDS.get(exam_type, 12))
    licence_id = lp["licence_id"]
    vehicle_type_id = lp["vehicle_type_id"]
    date_from = config.get("date_from", "2020-01-01")
    date_to = config.get("date_to", "2030-12-31")
    selected_locs = [l.lower() for l in config.get("locations", [])]

    all_loc_data = load_location_ids()
    licence_locs = all_loc_data.get(licence_type, all_loc_data)
    if isinstance(licence_locs, dict):
        all_ids = licence_locs.get(exam_type, [])
    else:
        all_ids = licence_locs
    if not all_ids:
        return jsonify({"ok": True, "times": [], "added": [], "removed": []})

    # If specific locations selected, only scan those
    if selected_locs:
        # Build name->id map from location_details, but only for IDs valid for this licence/exam
        valid_id_set = set(all_ids)
        loc_detail_map = {}
        if LOCATION_DETAILS_PATH.exists():
            with open(LOCATION_DETAILS_PATH, "r") as f:
                for loc in json.load(f).get("locations", []):
                    lid = loc["id"]
                    name = loc["name"].lower()
                    # Prefer IDs that match the current licence type's valid locations
                    if lid in valid_id_set:
                        loc_detail_map[name] = lid
                    elif name not in loc_detail_map:
                        loc_detail_map[name] = lid
        scan_ids = [loc_detail_map[n] for n in selected_locs if n in loc_detail_map]
        # Only keep IDs that are valid for this licence type
        scan_ids = [sid for sid in scan_ids if sid in valid_id_set] or scan_ids
        if not scan_ids:
            scan_ids = all_ids
    else:
        scan_ids = all_ids

    app.logger.info("Scanning location IDs: %s (licence=%s, exam=%s/%s)",
                     scan_ids, licence_type, exam_type, exam_type_id)

    # Parallel scan using thread pool
    collected = []
    with ThreadPoolExecutor(max_workers=8) as executor:
        futures = {executor.submit(_fetch_location, ssn, exam_type_id, lid,
                                    licence_id, vehicle_type_id): lid
                   for lid in scan_ids}
        for future in as_completed(futures):
            try:
                result = future.result()
                collected.extend(result)
            except Exception:
                pass

    # Filter by date range
    collected = [t for t in collected if date_from <= t["date"] <= date_to]

    # Filter by selected locations (API may return nearby/unrelated locations)
    if selected_locs:
        collected = [t for t in collected if t.get("location", "").lower() in selected_locs]

    collected.sort(key=lambda t: t["date"] + t["time"])

    # Compute changes vs previous snapshot
    previous = load_snapshot()
    current_keys = {make_key(t): t for t in collected}
    previous_keys = {make_key(t): t for t in previous}
    added = [current_keys[k] for k in current_keys if k not in previous_keys]
    removed = [previous_keys[k] for k in previous_keys if k not in current_keys]

    save_snapshot(collected)

    # Send SMS notification for slots not recently notified (independent of snapshot diff).
    # Using snapshot-based "added" alone is unreliable because a slot may already be in
    # the snapshot from a prior scan run, so we dedupe by slot key with a TTL instead.
    sms_enabled = bool(config.get("sms_enabled"))
    sms_to = config.get("sms_to", "").strip()
    # Prefer env vars (safer in deployment) but fall back to config.json
    sms_user = os.environ.get("SMS_API_USERNAME") or config.get("sms_api_username", "")
    sms_pass = os.environ.get("SMS_API_PASSWORD") or config.get("sms_api_password", "")
    sms_configured = sms_enabled and sms_to and sms_user and sms_pass

    ntfy_enabled = bool(config.get("ntfy_enabled"))
    ntfy_topic = (config.get("ntfy_topic") or "").strip()
    ntfy_server = (config.get("ntfy_server") or "https://ntfy.sh").strip()
    ntfy_configured = ntfy_enabled and ntfy_topic

    notified = load_sms_notified()
    to_notify = [t for t in collected if make_key(t) not in notified]

    def _build_message():
        dn = ["sön", "mån", "tis", "ons", "tor", "fre", "lör"]
        mn = ["jan", "feb", "mar", "apr", "maj", "jun", "jul", "aug", "sep", "okt", "nov", "dec"]
        lines = []
        for t in sorted(to_notify, key=lambda x: x["date"] + x["time"])[:5]:
            try:
                from datetime import date as _date
                parts = t["date"].split("-")
                d = _date(int(parts[0]), int(parts[1]), int(parts[2]))
                dl = f"{dn[(d.weekday() + 1) % 7]} {d.day} {mn[d.month - 1]}"
            except Exception:
                dl = t["date"]
            lines.append(f"{dl} {t['time']} - {t['location']}")
        msg = "Ledig provtid hittad!\n" + "\n".join(lines)
        if len(to_notify) > 5:
            msg += f"\n+{len(to_notify) - 5} fler tider"
        return msg

    any_sent_ok = False

    if to_notify and ntfy_configured:
        try:
            ntfy_result = send_ntfy(ntfy_topic, "Ledig provtid hittad!",
                                    _build_message(), server=ntfy_server)
        except Exception as e:
            app.logger.error("ntfy send failed: %s", e)
            ntfy_result = {"ok": False, "error": str(e)}
        if ntfy_result.get("ok"):
            any_sent_ok = True
        log = load_activity_log()
        log.append({
            "type": "ntfy_sent" if ntfy_result.get("ok") else "ntfy_failed",
            "time": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "topic": ntfy_topic,
            "notified_count": len(to_notify),
            "result": {k: ntfy_result.get(k) for k in ("ok", "status", "error") if k in ntfy_result},
        })
        save_activity_log(log)

    if to_notify and sms_configured:
        msg = _build_message()
        sms_result = {"ok": False, "error": "not attempted"}
        try:
            sms_result = send_sms(sms_to, msg, sms_user, sms_pass)
        except Exception as e:
            app.logger.error("SMS send failed: %s", e)
            sms_result = {"ok": False, "error": str(e)}

        if sms_result.get("ok"):
            any_sent_ok = True

        log = load_activity_log()
        log.append({
            "type": "sms_sent" if sms_result.get("ok") else "sms_failed",
            "time": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "to": sms_to,
            "notified_count": len(to_notify),
            "result": {k: sms_result.get(k) for k in ("ok", "status", "error") if k in sms_result},
        })
        save_activity_log(log)

    if to_notify and any_sent_ok:
        expiry = (datetime.now(timezone.utc)
                  + timedelta(minutes=SMS_NOTIFY_TTL_MINUTES)
                  ).isoformat().replace("+00:00", "Z")
        for t in to_notify:
            notified[make_key(t)] = expiry
        save_sms_notified(notified)

    if to_notify and not sms_configured and not ntfy_configured:
        app.logger.info(
            "New slots found (%d) but no notification channel configured "
            "(sms_enabled=%s, ntfy_enabled=%s)",
            len(to_notify), sms_enabled, ntfy_enabled,
        )
        log = load_activity_log()
        log.append({
            "type": "notify_skipped",
            "time": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "reason": "no_channel_configured",
            "notified_count": len(to_notify),
            "sms_enabled": sms_enabled,
            "ntfy_enabled": ntfy_enabled,
        })
        save_activity_log(log)

    return jsonify({"ok": True, "times": collected, "added": added, "removed": removed})


@app.route("/api/location_ids")
def api_location_ids():
    """Return all location IDs for the requested exam type."""
    exam_type = request.args.get("exam_type", "Körprov")
    ids = load_location_ids().get(exam_type, [])
    return jsonify(ids)


@app.route("/api/reserve", methods=["POST"])
def api_reserve():
    """Create a 15-minute reservation hold on a found time slot."""
    data = request.json
    slot = data.get("slot", {})

    # Make sure the slot carries a location_id so the Boka button can deep-link
    # to the correct Trafikverket location.
    if not slot.get("location_id") and slot.get("location") and LOCATION_DETAILS_PATH.exists():
        try:
            with open(LOCATION_DETAILS_PATH, "r") as f:
                wanted = slot["location"].lower()
                for loc in json.load(f).get("locations", []):
                    if loc.get("name", "").lower() == wanted:
                        slot["location_id"] = loc["id"]
                        break
        except Exception:
            pass

    now = datetime.now(timezone.utc)
    expires = now + timedelta(minutes=RESERVATION_HOLD_MINUTES)

    reservation = {
        "id": str(uuid.uuid4()),
        "slot": slot,
        "created_at": now.isoformat().replace("+00:00", "Z"),
        "expires_at": expires.isoformat().replace("+00:00", "Z"),
        "status": "held",  # held | booked | dismissed | expired
    }

    reservations = load_reservations()
    # Expire old ones
    now_str = now.isoformat().replace("+00:00", "Z")
    reservations = [
        r for r in reservations
        if r["status"] in ("held",) and r["expires_at"] > now_str
           or r["status"] in ("booked", "dismissed")
    ]
    reservations.append(reservation)
    save_reservations(reservations)

    # Add to activity log
    log = load_activity_log()
    log.append({
        "type": "found",
        "time": now.isoformat().replace("+00:00", "Z"),
        "slot": slot,
    })
    save_activity_log(log)

    return jsonify(reservation)


@app.route("/api/reservation/<res_id>", methods=["PATCH"])
def api_update_reservation(res_id):
    """Update reservation status (booked or dismissed)."""
    data = request.json
    new_status = data.get("status", "dismissed")
    reservations = load_reservations()
    for r in reservations:
        if r["id"] == res_id:
            r["status"] = new_status
            break
    save_reservations(reservations)

    if new_status == "booked":
        log = load_activity_log()
        log.append({
            "type": "booked",
            "time": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "reservation_id": res_id,
        })
        save_activity_log(log)

    return jsonify({"status": "ok"})


@app.route("/api/reservations")
def api_reservations():
    """Return active reservations (not expired/dismissed)."""
    now_str = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    reservations = load_reservations()
    active = [
        r for r in reservations
        if r["status"] == "held" and r["expires_at"] > now_str
    ]
    return jsonify(active)


@app.route("/api/activity_log")
def api_activity_log():
    """Return recent activity log entries."""
    log = load_activity_log()
    return jsonify(log[-50:])


@app.route("/known_locations")
def known_locations():
    """Return location names seen in the last snapshot."""
    snapshot = load_snapshot()
    names = sorted(set(t["location"] for t in snapshot if t.get("location")))
    return jsonify(names)


@app.route("/api/sms/test", methods=["POST"])
def api_sms_test():
    """Send a test SMS to verify 46elks credentials."""
    config = load_config()
    to = config.get("sms_to", "")
    user = os.environ.get("SMS_API_USERNAME") or config.get("sms_api_username", "")
    pwd = os.environ.get("SMS_API_PASSWORD") or config.get("sms_api_password", "")
    if not to or not user or not pwd:
        return jsonify({"ok": False, "error": "Fyll i telefonnummer och 46elks-uppgifter först"})
    result = send_sms(to, "Test från Provbokningsbevakning - SMS fungerar!", user, pwd)
    return jsonify(result)


@app.route("/api/ntfy/test", methods=["POST"])
def api_ntfy_test():
    """Send a test ntfy notification to verify the topic works on Windows."""
    config = load_config()
    body = request.get_json(silent=True) or {}
    topic = (body.get("topic") or config.get("ntfy_topic") or "").strip()
    server = (body.get("server") or config.get("ntfy_server") or "https://ntfy.sh").strip()
    if not topic:
        return jsonify({"ok": False, "error": "Fyll i ett ntfy-topic först"})
    result = send_ntfy(topic, "Provbok test",
                        "Test från Provbokningsbevakning - ntfy fungerar!",
                        server=server)
    return jsonify(result)


@app.route("/api/location_details")
def api_location_details():
    """Return all locations with name, id, and region."""
    if LOCATION_DETAILS_PATH.exists():
        with open(LOCATION_DETAILS_PATH, "r") as f:
            data = json.load(f)
        return jsonify(data.get("locations", []))
    return jsonify([])


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "5000"))
    debug = os.environ.get("FLASK_DEBUG", "1") not in ("0", "false", "False", "")
    app.run(host="0.0.0.0", port=port, debug=debug, threaded=True)
