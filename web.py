#!/usr/bin/env python3
"""
Flask web UI for Trafikverket körkortsprov checker.

Server-side scanning with BankID authentication.
The server maintains an authenticated session with Trafikverket and
scans for available driving test times.
"""

import json
import uuid
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timedelta, timezone
from pathlib import Path

import requests as http_requests
from flask import Flask, render_template, request, jsonify

app = Flask(__name__)

PROJECT_DIR = Path(__file__).parent
CONFIG_PATH = PROJECT_DIR / "config.json"
LOCATIONS_PATH = PROJECT_DIR / "data" / "valid_locations.json"
LOCATION_DETAILS_PATH = PROJECT_DIR / "data" / "location_details.json"
SNAPSHOT_PATH = PROJECT_DIR / "data" / "last_snapshot.json"
RESERVATIONS_PATH = PROJECT_DIR / "data" / "reservations.json"
LOG_PATH = PROJECT_DIR / "data" / "activity_log.json"

RESERVATION_HOLD_MINUTES = 15
TV_BASE = "https://fp.trafikverket.se/Boka"
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


def send_sms(to: str, message: str, api_user: str, api_pass: str) -> dict:
    """Send an SMS via 46elks API."""
    try:
        r = http_requests.post(
            "https://api.46elks.com/a1/sms",
            auth=(api_user, api_pass),
            data={"from": "Provbok", "to": to, "message": message},
            timeout=15,
            proxies={"http": None, "https": None},
            verify=False,
        )
        return {"ok": r.status_code == 200, "status": r.status_code, "data": r.text}
    except Exception as e:
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
    config["mode"] = data.get("mode", "manual")
    config["sms_enabled"] = data.get("sms_enabled", False)
    config["sms_to"] = data.get("sms_to", "").strip()
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

    # Send SMS notification for new slots
    if added and config.get("sms_enabled") and config.get("sms_to") and config.get("sms_api_username"):
        dn = ["sön", "mån", "tis", "ons", "tor", "fre", "lör"]
        mn = ["jan", "feb", "mar", "apr", "maj", "jun", "jul", "aug", "sep", "okt", "nov", "dec"]
        lines = []
        for t in sorted(added, key=lambda x: x["date"] + x["time"])[:5]:
            try:
                from datetime import date as _date
                parts = t["date"].split("-")
                d = _date(int(parts[0]), int(parts[1]), int(parts[2]))
                # weekday(): mon=0..sun=6, dn index: sön=0,mån=1..lör=6
                dl = f"{dn[(d.weekday() + 1) % 7]} {d.day} {mn[d.month - 1]}"
            except Exception:
                dl = t["date"]
            lines.append(f"{dl} {t['time']} - {t['location']}")
        msg = f"Ledig provtid hittad!\n" + "\n".join(lines)
        if len(added) > 5:
            msg += f"\n+{len(added) - 5} fler tider"
        try:
            send_sms(config["sms_to"], msg, config["sms_api_username"], config["sms_api_password"])
        except Exception as e:
            app.logger.error("SMS send failed: %s", e)

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
    user = config.get("sms_api_username", "")
    pwd = config.get("sms_api_password", "")
    if not to or not user or not pwd:
        return jsonify({"ok": False, "error": "Fyll i telefonnummer och 46elks-uppgifter först"})
    result = send_sms(to, "Test från Provbokningsbevakning - SMS fungerar!", user, pwd)
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
    app.run(host="0.0.0.0", port=5000, debug=True, threaded=True)
