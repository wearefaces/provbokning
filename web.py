#!/usr/bin/env python3
"""
Flask web UI for Trafikverket körkortsprov checker.

Server-side scanning with BankID authentication.
The server maintains an authenticated session with Trafikverket and
scans for available driving test times.
"""
from __future__ import annotations

import json
import os
import re
import smtplib
import ssl
import uuid
import hmac
import threading
from email.message import EmailMessage
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timedelta, timezone
from pathlib import Path

import requests as http_requests
from flask import (
    Flask, Response, abort, redirect, render_template, request, jsonify,
    send_from_directory, session, url_for,
)
try:
    from flask_cors import CORS  # type: ignore
except ImportError:  # pragma: no cover
    CORS = None

app = Flask(__name__)
# Secret key for session cookies. Generate with: python -c "import secrets; print(secrets.token_hex(32))"
app.secret_key = os.environ.get("SECRET_KEY") or os.urandom(32)
_cookie_secure = os.environ.get("COOKIE_SECURE", "0") in ("1", "true", "True")
app.config.update(
    SESSION_COOKIE_HTTPONLY=True,
    # SameSite=None requires Secure; needed so the Flutter web/mobile client
    # (different origin) can keep the Flask session cookie on /api/* calls.
    SESSION_COOKIE_SAMESITE="None" if _cookie_secure else "Lax",
    SESSION_COOKIE_SECURE=_cookie_secure,
)

# CORS for the mobile / web Flutter client. Allowed origins come from
# CORS_ORIGINS env (comma-separated). Defaults cover the local dev server.
_cors_origins = [o.strip() for o in os.environ.get(
    "CORS_ORIGINS",
    "http://localhost:8080,http://127.0.0.1:8080,http://localhost:5000"
).split(",") if o.strip()]
if CORS is not None:
    CORS(app, resources={r"/api/*": {"origins": _cors_origins}},
         supports_credentials=True)

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
SUBSCRIBERS_PATH = DATA_DIR / "subscribers.json"
PAID_SESSIONS_PATH = DATA_DIR / "paid_sessions.json"

# ── Login (form-based session auth; set LOGIN_USER + LOGIN_PASS env vars) ──
# Backwards compatible with the old BASIC_AUTH_USER / BASIC_AUTH_PASS names.
LOGIN_USER = os.environ.get("LOGIN_USER") or os.environ.get("BASIC_AUTH_USER", "")
LOGIN_PASS = os.environ.get("LOGIN_PASS") or os.environ.get("BASIC_AUTH_PASS", "")

# Endpoints that REQUIRE admin login. Everything else is public.
# BankID is the user-level auth for actually using the service; the
# username/password login here only protects admin-only configuration.
_ADMIN_ENDPOINTS = {
    "admin", "save_admin_config",
    "api_sms_test", "api_email_test", "api_ntfy_test",
    "api_subscribers_list", "api_subscribers_delete",
}


def _is_admin() -> bool:
    if not LOGIN_USER or not LOGIN_PASS:
        return True  # auth disabled → effectively always admin
    return session.get("user") == LOGIN_USER


@app.before_request
def _require_login():
    if not LOGIN_USER or not LOGIN_PASS:
        return None  # auth disabled
    if request.endpoint not in _ADMIN_ENDPOINTS:
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
        return redirect(url_for("admin"))
    error = None
    if request.method == "POST":
        username = (request.form.get("username") or "").strip()
        password = request.form.get("password") or ""
        if username == LOGIN_USER and password == LOGIN_PASS:
            session.clear()
            session["user"] = LOGIN_USER
            session.permanent = True
            nxt = request.args.get("next") or url_for("admin")
            # Only allow same-site relative redirects
            if not nxt.startswith("/") or nxt.startswith("//"):
                nxt = url_for("admin")
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
    """Send an SMS via 46elks API.

    Tries an alphanumeric "Provbok" sender first. If 46elks rejects it with
    a 403 (typically because the account hasn't approved the alphanumeric
    sender ID), retries once with the account's first allocated number as
    sender so the message still goes out.

    If `SMS_RELAY_URL` env var is set, the call is forwarded to that URL
    (typically the production server) instead of going to 46elks directly.
    Use this on dev machines whose outbound traffic to api.46elks.com is
    blocked by a corporate proxy. The relay must accept POST JSON
    `{to, message}` with `Authorization: Bearer <SMS_RELAY_TOKEN>`.
    """
    # Normalise the recipient to E.164. 46elks requires a leading '+'.
    # Common Swedish input forms: "0701234567", "46701234567", "+46701234567".
    raw = (to or "").strip().replace(" ", "").replace("-", "")
    if raw.startswith("00"):
        to = "+" + raw[2:]
    elif raw.startswith("+"):
        to = raw
    elif raw.startswith("0"):
        to = "+46" + raw[1:]  # Swedish national → international
    elif raw.isdigit():
        to = "+" + raw
    else:
        to = raw
    relay_url = os.environ.get("SMS_RELAY_URL", "").strip()
    if relay_url:
        relay_token = os.environ.get("SMS_RELAY_TOKEN", "").strip()
        try:
            r = _notify_session.post(
                relay_url,
                json={"to": to, "message": message},
                headers={"Authorization": f"Bearer {relay_token}"} if relay_token else {},
                timeout=20,
                proxies={"http": None, "https": None},
                verify=CA_BUNDLE,
            )
            try:
                payload = r.json()
            except Exception:
                payload = {"data": (r.text or "")[:300]}
            ok = r.status_code == 200 and bool(payload.get("ok"))
            app.logger.info(
                "SMS relay -> %s status=%s ok=%s body=%s",
                relay_url, r.status_code, ok, str(payload)[:300],
            )
            if ok:
                return payload
            return {
                "ok": False,
                "status": r.status_code,
                "data": str(payload)[:300],
                "error": payload.get("error") or f"relay {r.status_code}",
                "relay": True,
            }
        except Exception as e:
            app.logger.error("SMS relay exception: %s", e)
            return {"ok": False, "error": f"relay error: {e}", "relay": True}

    def _post(from_value: str | None) -> dict:
        data = {"to": to, "message": message}
        if from_value:
            data["from"] = from_value
        r = _notify_session.post(
            "https://api.46elks.com/a1/sms",
            auth=(api_user, api_pass),
            data=data,
            timeout=15,
            proxies={"http": None, "https": None},
            verify=CA_BUNDLE,
        )
        ok = r.status_code == 200
        body = (r.text or "")[:300]
        sender_label = from_value or "<default>"
        app.logger.info(
            "SMS to %s from=%s -> status=%s body=%s",
            to, sender_label, r.status_code, body,
        )
        return {"ok": ok, "status": r.status_code, "data": body, "from": sender_label}

    try:
        result = _post("Provbok")
    except Exception as e:
        app.logger.error("SMS exception: %s", e)
        return {"ok": False, "error": str(e)}

    # 403 from 46elks usually means the alphanumeric sender id isn't
    # approved on the account. Fall back to the first allocated number.
    if not result["ok"] and result.get("status") == 403:
        try:
            num = _46elks_first_number(api_user, api_pass)
        except Exception as e:
            app.logger.warning("46elks number lookup failed: %s", e)
            num = None
        if num:
            try:
                retry = _post(num)
                if retry["ok"]:
                    return retry
                # Surface the retry's error if it also failed.
                result = retry
            except Exception as e:
                app.logger.error("SMS numeric retry exception: %s", e)

    # Final fallback: omit explicit sender and let 46elks choose account default.
    if not result["ok"] and result.get("status") == 403:
        try:
            retry_default = _post(None)
            if retry_default["ok"]:
                return retry_default
            result = retry_default
        except Exception as e:
            app.logger.error("SMS default-sender retry exception: %s", e)

    if not result["ok"]:
        result["error"] = (
            f"46elks {result.get('status')}: {result.get('data') or 'okänt fel'}"
        )
    return result


def _46elks_first_number(api_user: str, api_pass: str) -> str | None:
    """Return the first allocated 46elks phone number for the account, or None."""
    r = _notify_session.get(
        "https://api.46elks.com/a1/numbers",
        auth=(api_user, api_pass),
        timeout=10,
        proxies={"http": None, "https": None},
        verify=CA_BUNDLE,
    )
    if r.status_code != 200:
        return None
    data = r.json() or {}
    for n in (data.get("data") or []):
        if n.get("active") in ("yes", True) and n.get("number"):
            return n["number"]
    return None


def send_email(to: str, subject: str, body: str) -> dict:
    """Send email via SMTP. Reads SMTP_HOST/PORT/USER/PASS/FROM env vars or config."""
    config = load_config()
    host = os.environ.get("SMTP_HOST") or config.get("smtp_host", "")
    port = int(os.environ.get("SMTP_PORT") or config.get("smtp_port") or 587)
    user = os.environ.get("SMTP_USER") or config.get("smtp_user", "")
    pwd  = os.environ.get("SMTP_PASS") or config.get("smtp_pass", "")
    sender = os.environ.get("SMTP_FROM") or config.get("smtp_from") or user
    if not host or not sender:
        return {"ok": False, "error": "SMTP not configured"}
    msg = EmailMessage()
    msg["From"] = sender
    msg["To"] = to
    msg["Subject"] = subject
    msg.set_content(body)
    try:
        if port == 465:
            with smtplib.SMTP_SSL(host, port, timeout=20, context=ssl.create_default_context()) as s:
                if user:
                    s.login(user, pwd)
                s.send_message(msg)
        else:
            with smtplib.SMTP(host, port, timeout=20) as s:
                s.ehlo()
                try:
                    s.starttls(context=ssl.create_default_context())
                    s.ehlo()
                except smtplib.SMTPException:
                    pass
                if user:
                    s.login(user, pwd)
                s.send_message(msg)
        app.logger.info("Email to %s sent (subject=%s)", to, subject)
        return {"ok": True}
    except Exception as e:
        app.logger.error("Email exception: %s", e)
        return {"ok": False, "error": str(e)}


# ── Subscribers ──

_EMAIL_RE = re.compile(r"^[^\s@]+@[^\s@]+\.[^\s@]+$")
_PHONE_RE = re.compile(r"^\+?[0-9]{6,15}$")


def load_subscribers() -> list[dict]:
    if not SUBSCRIBERS_PATH.exists():
        return []
    try:
        with open(SUBSCRIBERS_PATH, "r") as f:
            return json.load(f)
    except Exception:
        return []


def save_subscribers(subs: list[dict]):
    with open(SUBSCRIBERS_PATH, "w") as f:
        json.dump(subs, f, indent=2, ensure_ascii=False)


# ── Paid sessions (demo → live upgrade tied to Flask session) ──

def load_paid_sessions() -> dict:
    if not PAID_SESSIONS_PATH.exists():
        return {}
    try:
        with open(PAID_SESSIONS_PATH, "r") as f:
            return json.load(f) or {}
    except Exception:
        return {}


def save_paid_sessions(d: dict):
    with open(PAID_SESSIONS_PATH, "w") as f:
        json.dump(d, f, indent=2, ensure_ascii=False)


def _current_sid() -> str:
    """Stable per-browser session id used as Stripe client_reference_id."""
    sid = session.get("sid")
    if not sid:
        sid = uuid.uuid4().hex
        session["sid"] = sid
        session.permanent = True
    return sid


def _entry_is_active(entry: dict | None) -> bool:
    if not entry or not entry.get("paid"):
        return False
    pu = entry.get("paid_until")
    if pu:
        try:
            until = datetime.fromisoformat(pu.replace("Z", "+00:00"))
            if until < datetime.now(timezone.utc):
                return False
        except Exception:
            pass
    return True


def is_session_paid() -> bool:
    """Return True if current visitor has an active paid subscription.

    Looks up by Flask session id first; falls back to any paid record
    matching the email stored in this session (so a user that already paid
    via the web/Stripe is auto-recognised on the mobile app after they
    enter their email in Settings).
    """
    sid = session.get("sid")
    if sid:
        entry = load_paid_sessions().get(sid)
        if _entry_is_active(entry):
            return True
    email = (session.get("email") or "").strip().lower()
    if email:
        _src_sid, src = _find_paid_entry_by_email(email)
        if _entry_is_active(src):
            # Auto-promote the current sid so subsequent calls are O(1).
            if sid:
                _link_session_to_email(sid, email)
            return True
    return False


def mark_session_paid(sid: str, customer_id: str = "", subscription_id: str = "",
                     days: int = 33, email: str = "", source: str = ""):
    store = load_paid_sessions()
    until = (datetime.now(timezone.utc) + timedelta(days=days)).isoformat().replace("+00:00", "Z")
    prev = store.get(sid, {}) or {}
    store[sid] = {
        "paid": True,
        "paid_until": until,
        "stripe_customer_id": customer_id or prev.get("stripe_customer_id", ""),
        "stripe_subscription_id": subscription_id or prev.get("stripe_subscription_id", ""),
        "email": (email or prev.get("email", "") or "").strip().lower(),
        "source": source or prev.get("source", ""),
        "updated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    }
    save_paid_sessions(store)


def _find_paid_entry_by_email(email: str) -> tuple[str, dict] | tuple[None, None]:
    """Return (sid, entry) of the most-recent paid record matching the given
    email, or (None, None) if no match."""
    if not email:
        return None, None
    needle = email.strip().lower()
    if not needle:
        return None, None
    best_sid, best_entry, best_ts = None, None, ""
    for sid, entry in load_paid_sessions().items():
        if (entry.get("email") or "").strip().lower() != needle:
            continue
        if not entry.get("paid"):
            continue
        ts = entry.get("updated_at") or ""
        if ts >= best_ts:
            best_ts = ts
            best_sid = sid
            best_entry = entry
    return best_sid, best_entry


def _link_session_to_email(sid: str, email: str) -> bool:
    """If another paid record exists for `email`, copy paid status onto the
    current sid. Returns True if a link was applied."""
    src_sid, src = _find_paid_entry_by_email(email)
    if not src or src_sid == sid:
        # Always at least stamp the email on the current sid so future lookups
        # work, even if there's no existing paid record yet.
        store = load_paid_sessions()
        entry = store.get(sid, {}) or {}
        entry["email"] = (email or "").strip().lower()
        entry["updated_at"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        store[sid] = entry
        save_paid_sessions(store)
        return False
    store = load_paid_sessions()
    store[sid] = {
        "paid": True,
        "paid_until": src.get("paid_until"),
        "stripe_customer_id": src.get("stripe_customer_id", ""),
        "stripe_subscription_id": src.get("stripe_subscription_id", ""),
        "email": (email or "").strip().lower(),
        "source": src.get("source", "") or "linked",
        "linked_from_sid": src_sid,
        "updated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    }
    save_paid_sessions(store)
    return True


def mark_session_unpaid_by_customer(customer_id: str):
    if not customer_id:
        return
    store = load_paid_sessions()
    changed = False
    for sid, entry in store.items():
        if entry.get("stripe_customer_id") == customer_id and entry.get("paid"):
            entry["paid"] = False
            entry["updated_at"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            changed = True
    if changed:
        save_paid_sessions(store)


# ── Stripe configuration ──
STRIPE_SECRET_KEY = os.environ.get("STRIPE_SECRET_KEY", "").strip()
STRIPE_PUBLISHABLE_KEY = os.environ.get("STRIPE_PUBLISHABLE_KEY", "").strip()
STRIPE_PRICE_ID = os.environ.get("STRIPE_PRICE_ID", "").strip()
STRIPE_WEBHOOK_SECRET = os.environ.get("STRIPE_WEBHOOK_SECRET", "").strip()
SUBSCRIPTION_PRICE_LABEL = os.environ.get("SUBSCRIPTION_PRICE_LABEL", "99 kr/mån").strip()

_stripe = None
if STRIPE_SECRET_KEY:
    try:
        import stripe as _stripe_mod  # type: ignore
        _stripe_mod.api_key = STRIPE_SECRET_KEY
        _stripe = _stripe_mod
    except ImportError:
        app.logger.warning("stripe package not installed; payment disabled")


def stripe_enabled() -> bool:
    return bool(_stripe and STRIPE_PRICE_ID)


def is_sub_paid(sub: dict) -> bool:
    """Return True if subscriber is allowed to receive notifications.
    Without Stripe configured, all active subscribers count as paid (free mode).
    With Stripe, requires `paid` flag and a future `paid_until` if set."""
    if not sub.get("active"):
        return False
    if not stripe_enabled():
        return True  # free mode while payment not configured
    if not sub.get("paid"):
        return False
    pu = sub.get("paid_until")
    if pu:
        try:
            until = datetime.fromisoformat(pu.replace("Z", "+00:00"))
            if until < datetime.now(timezone.utc):
                return False
        except Exception:
            pass
    return True


def _normalize_phone(p: str) -> str:
    p = re.sub(r"[\s\-()]", "", p or "")
    if p.startswith("00"):
        p = "+" + p[2:]
    if p.startswith("0"):
        # Default to Swedish country code
        p = "+46" + p[1:]
    return p


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
    return render_template("landing.html")


@app.route("/privacy")
@app.route("/privacy/")
def privacy():
    from datetime import date
    return render_template("privacy.html", updated=date.today().isoformat())


@app.route("/app")
def app_page():
    config = load_config()
    return render_template("index.html", config=config)


@app.route("/test/book")
def test_book_page():
    """Isolated test page for the new /api/book_slot endpoint.

    Not linked from the main UI — only reachable by typing the URL.
    Lists slots from the latest scan snapshot and lets the user attempt a
    Trafikverket /create-reservation claim on any of them.
    """
    snapshot = load_snapshot()
    snapshot = sorted(snapshot, key=lambda t: t.get("date", "") + t.get("time", ""))
    return render_template(
        "test_book.html",
        slots=snapshot,
        authenticated=auth_state["authenticated"],
    )


# ── Flutter mobile web app, served same-origin under /m/ ──
MOBILE_WEB_DIR = PROJECT_DIR / "mobile" / "build" / "web"


@app.route("/m/")
@app.route("/m")
def mobile_index():
    if not (MOBILE_WEB_DIR / "index.html").exists():
        abort(404)
    return send_from_directory(MOBILE_WEB_DIR, "index.html")


@app.route("/m/<path:filename>")
def mobile_assets(filename):
    if not MOBILE_WEB_DIR.exists():
        abort(404)
    full = (MOBILE_WEB_DIR / filename)
    if not full.exists() or full.is_dir():
        # Flutter SPA fallback
        return send_from_directory(MOBILE_WEB_DIR, "index.html")
    return send_from_directory(MOBILE_WEB_DIR, filename)


@app.route("/robots.txt")
def robots_txt():
    body = (
        "User-agent: *\n"
        "Allow: /\n"
        "Disallow: /admin\n"
        "Disallow: /api/\n"
        f"Sitemap: {request.url_root}sitemap.xml\n"
    )
    return Response(body, mimetype="text/plain")


@app.route("/sitemap.xml")
def sitemap_xml():
    base = request.url_root.rstrip("/")
    urls = ["/", "/app", "/subscribe"]
    items = "".join(
        f"<url><loc>{base}{u}</loc><changefreq>weekly</changefreq>"
        f"<priority>{'1.0' if u == '/' else '0.8'}</priority></url>"
        for u in urls
    )
    body = (
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
        f"{items}</urlset>"
    )
    return Response(body, mimetype="application/xml")


@app.route("/admin")
def admin():
    config = load_config()
    return render_template("admin.html", config=config)


@app.route("/subscribe")
def public_subscribe_page():
    return render_template("subscribe.html")


# ── Subscriber API (public) ──


@app.route("/api/subscribe", methods=["POST"])
def api_subscribe():
    data = request.get_json(silent=True) or {}
    phone_raw = (data.get("phone") or "").strip()
    email = (data.get("email") or "").strip().lower()
    name = (data.get("name") or "").strip()[:80]

    phone = _normalize_phone(phone_raw) if phone_raw else ""
    if not phone and not email:
        return jsonify({"ok": False, "error": "Ange telefonnummer eller e-post"}), 400
    if phone and not _PHONE_RE.match(phone):
        return jsonify({"ok": False, "error": "Ogiltigt telefonnummer"}), 400
    if email and not _EMAIL_RE.match(email):
        return jsonify({"ok": False, "error": "Ogiltig e-postadress"}), 400

    subs = load_subscribers()
    # Deduplicate by phone or email (re-activate if previously removed)
    existing = None
    for s in subs:
        if (phone and s.get("phone") == phone) or (email and s.get("email") == email):
            s["phone"] = phone or s.get("phone", "")
            s["email"] = email or s.get("email", "")
            if name:
                s["name"] = name
            s["active"] = True
            existing = s
            break

    if existing is None:
        existing = {
            "id": str(uuid.uuid4()),
            "name": name,
            "phone": phone,
            "email": email,
            "active": True,
            "paid": not stripe_enabled(),  # free mode = auto-paid
            "created_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "unsubscribe_token": uuid.uuid4().hex,
        }
        subs.append(existing)
    save_subscribers(subs)

    # If Stripe is configured, create a Checkout Session and return its URL
    if stripe_enabled():
        try:
            base = request.host_url.rstrip("/")
            customer_email = email or None
            cs = _stripe.checkout.Session.create(
                mode="subscription",
                line_items=[{"price": STRIPE_PRICE_ID, "quantity": 1}],
                customer_email=customer_email,
                client_reference_id=existing["id"],
                success_url=f"{base}/subscribe/thanks?sid={existing['id']}",
                cancel_url=f"{base}/?canceled=1",
                metadata={"subscriber_id": existing["id"]},
                allow_promotion_codes=True,
                locale="sv",
            )
            return jsonify({"ok": True, "id": existing["id"], "checkout_url": cs.url})
        except Exception as e:
            app.logger.error("Stripe checkout create failed: %s", e)
            return jsonify({"ok": False, "error": f"Betalsystemfel: {e}"}), 500

    return jsonify({"ok": True, "id": existing["id"]})


@app.route("/subscribe/thanks")
def subscribe_thanks():
    return render_template("subscribe.html", thanks=True)


@app.route("/api/payment/config")
def api_payment_config():
    return jsonify({
        "stripe_enabled": stripe_enabled(),
        "price_label": SUBSCRIPTION_PRICE_LABEL,
    })


# ── Billing: demo → live upgrade for the BankID app ──

@app.route("/api/billing/status")
def api_billing_status():
    """Returns whether the current visitor has live access or is in demo mode."""
    sid = _current_sid()
    paid = is_session_paid()
    entry = load_paid_sessions().get(sid, {}) or {}
    src = (entry.get("source") or "").lower()
    return jsonify({
        "paid": paid,
        "demo": not paid,
        "stripe_enabled": stripe_enabled(),
        "price_label": SUBSCRIPTION_PRICE_LABEL,
        "paid_until": entry.get("paid_until") if paid else None,
        "source": src,
        "email": (session.get("email") or entry.get("email") or "") if paid else "",
    })


# ── Profile (email + display name kept in the Flask session) ──

@app.route("/api/profile", methods=["GET"])
def api_profile_get():
    _current_sid()
    return jsonify({
        "email": session.get("email", ""),
        "name": session.get("name", ""),
    })


@app.route("/api/profile", methods=["POST"])
def api_profile_post():
    """Update the visitor's profile. If an email is supplied and another
    paid record already exists with that email (e.g. the user paid via
    Stripe on the web), copy the paid status onto this session."""
    sid = _current_sid()
    data = request.get_json(silent=True) or {}
    email = (data.get("email") or "").strip().lower()
    name = (data.get("name") or "").strip()
    if email:
        session["email"] = email
    if "name" in data:
        session["name"] = name
    session.permanent = True
    linked = False
    if email:
        try:
            linked = _link_session_to_email(sid, email)
        except Exception as e:
            app.logger.exception("profile link failed: %r", e)
    paid = is_session_paid()
    entry = load_paid_sessions().get(sid, {}) or {}
    return jsonify({
        "ok": True,
        "linked": linked,
        "email": session.get("email", ""),
        "name": session.get("name", ""),
        "paid": paid,
        "paid_until": entry.get("paid_until") if paid else None,
        "source": (entry.get("source") or "").lower(),
    })


@app.route("/api/billing/checkout", methods=["POST"])
def api_billing_checkout():
    """Create a Stripe Checkout Session to upgrade the current visitor to live."""
    if not stripe_enabled():
        return jsonify({"ok": False, "error": "Betalning är inte konfigurerad än"}), 503
    sid = _current_sid()
    data = request.get_json(silent=True) or {}
    email = (data.get("email") or "").strip().lower() or None
    try:
        base = request.host_url.rstrip("/")
        cs = _stripe.checkout.Session.create(
            mode="subscription",
            line_items=[{"price": STRIPE_PRICE_ID, "quantity": 1}],
            customer_email=email,
            client_reference_id=f"sid:{sid}",
            success_url=f"{base}/billing/thanks?cs={{CHECKOUT_SESSION_ID}}",
            cancel_url=f"{base}/app?billing=canceled",
            metadata={"sid": sid},
            allow_promotion_codes=True,
            locale="sv",
        )
        return jsonify({"ok": True, "checkout_url": cs.url})
    except Exception as e:
        app.logger.error("Billing checkout create failed: %s", e)
        return jsonify({"ok": False, "error": f"Betalsystemfel: {e}"}), 500


# Maps App Store / Play Store product IDs to the number of paid days they
# grant. Adjust if you add more tiers in App Store Connect.
IAP_PRODUCT_DAYS = {
    "se.provbok.sub.weekly": 7,
    "se.provbok.sub.monthly": 33,
}


@app.route("/api/billing/iap_unlock", methods=["POST"])
def api_billing_iap_unlock():
    """Mark the current visitor's session as paid based on a completed
    Apple/Google in-app purchase. The mobile app posts the receipt + product
    id after the StoreKit purchase resolves.

    NOTE: For production hardening you should validate the receipt against
    Apple's App Store Server API (or Google Play Developer API) before
    flipping the session to paid. This endpoint currently trusts the client
    receipt and only records the metadata for later auditing.
    """
    data = request.get_json(silent=True) or {}
    product_id = (data.get("product_id") or "").strip()
    transaction_id = (data.get("transaction_id") or "").strip()
    receipt = (data.get("receipt") or "").strip()
    platform = (data.get("platform") or "ios").strip().lower()
    if not product_id or not transaction_id:
        return jsonify({"ok": False, "error": "missing product_id/transaction_id"}), 400
    days = IAP_PRODUCT_DAYS.get(product_id)
    if days is None:
        return jsonify({"ok": False, "error": f"unknown product {product_id}"}), 400
    sid = _current_sid()
    try:
        mark_session_paid(
            sid,
            customer_id=f"{platform}_iap",
            subscription_id=transaction_id,
            days=days,
            email=(session.get("email") or "").strip().lower(),
            source=f"{platform}_iap",
        )
    except Exception as e:
        app.logger.error("IAP unlock failed: %s", e)
        return jsonify({"ok": False, "error": f"server_error: {e}"}), 500
    app.logger.info(
        "IAP unlock: sid=%s platform=%s product=%s tx=%s days=%d receipt_len=%d",
        sid, platform, product_id, transaction_id, days, len(receipt),
    )
    entry = load_paid_sessions().get(sid, {}) or {}
    return jsonify({
        "ok": True,
        "paid_until": entry.get("paid_until"),
        "days": days,
    })


@app.route("/billing/thanks")
def billing_thanks():
    """Stripe success_url. Verify the checkout session and mark visitor as paid."""
    cs_id = request.args.get("cs", "")
    if _stripe and cs_id and cs_id != "{CHECKOUT_SESSION_ID}":
        try:
            cs_obj = _stripe.checkout.Session.retrieve(cs_id)
            # Stripe SDK returns a StripeObject; dict(cs_obj) tries integer
            # indexing and raises KeyError(0). Use to_dict() / to_dict_recursive().
            if hasattr(cs_obj, "to_dict_recursive"):
                cs = cs_obj.to_dict_recursive()
            elif hasattr(cs_obj, "to_dict"):
                cs = cs_obj.to_dict()
            else:
                cs = {
                    "client_reference_id": getattr(cs_obj, "client_reference_id", None),
                    "payment_status": getattr(cs_obj, "payment_status", None),
                    "customer": getattr(cs_obj, "customer", None),
                    "subscription": getattr(cs_obj, "subscription", None),
                }
            ref = cs.get("client_reference_id") or ""
            payment_status = cs.get("payment_status")
            app.logger.info(
                "billing/thanks: cs_id=%s ref=%s payment_status=%s",
                cs_id, ref, payment_status,
            )
            # payment_status is "paid" for normal purchases or "no_payment_required"
            # when a 100%-off coupon zeros the total. Both count as a successful checkout.
            ok_status = payment_status in ("paid", "no_payment_required")
            if ref.startswith("sid:") and ok_status:
                cust_email = (cs.get("customer_email") or "").strip().lower()
                if not cust_email:
                    cd = cs.get("customer_details") or {}
                    cust_email = (cd.get("email") or "").strip().lower()
                mark_session_paid(
                    ref[4:],
                    customer_id=cs.get("customer") or "",
                    subscription_id=cs.get("subscription") or "",
                    email=cust_email,
                    source="stripe",
                )
                app.logger.info("billing/thanks: marked sid=%s as paid (email=%s)", ref[4:], cust_email or "-")
            else:
                app.logger.warning(
                    "billing/thanks: not marking paid (ref=%s, status=%s)",
                    ref, payment_status,
                )
        except Exception as e:
            app.logger.exception("billing/thanks verify failed: %r", e)
    return redirect("/app?billing=success")


@app.route("/api/stripe/webhook", methods=["POST"])
def stripe_webhook():
    if not _stripe:
        return jsonify({"ok": False, "error": "stripe not configured"}), 503
    payload = request.get_data()
    sig = request.headers.get("Stripe-Signature", "")
    try:
        if STRIPE_WEBHOOK_SECRET:
            event = _stripe.Webhook.construct_event(payload, sig, STRIPE_WEBHOOK_SECRET)
        else:
            event = json.loads(payload.decode("utf-8"))
    except Exception as e:
        app.logger.error("Stripe webhook parse failed: %s", e)
        return jsonify({"ok": False}), 400

    etype = event["type"] if isinstance(event, dict) else event.type
    obj = (event.get("data") or {}).get("object", {}) if isinstance(event, dict) else event["data"]["object"]

    subs = load_subscribers()
    changed = False

    def _find_by_id(sid):
        return next((x for x in subs if x.get("id") == sid), None)

    def _find_by_customer(cust_id):
        return next((x for x in subs if x.get("stripe_customer_id") == cust_id), None)

    if etype == "checkout.session.completed":
        ref = obj.get("client_reference_id") or ""
        # New flow: sid:<flask-session-id> — paid app access
        if ref.startswith("sid:"):
            cust_email = (obj.get("customer_email") or "").strip().lower()
            if not cust_email:
                cd = obj.get("customer_details") or {}
                cust_email = (cd.get("email") or "").strip().lower()
            mark_session_paid(
                ref[4:],
                customer_id=obj.get("customer") or "",
                subscription_id=obj.get("subscription") or "",
                email=cust_email,
                source="stripe",
            )
            return jsonify({"ok": True})
        # Legacy flow: subscriber id (SMS/email notification list)
        sid = (obj.get("metadata") or {}).get("subscriber_id") or ref
        sub = _find_by_id(sid) if sid else None
        if sub:
            sub["paid"] = True
            sub["stripe_customer_id"] = obj.get("customer")
            sub["stripe_subscription_id"] = obj.get("subscription")
            sub["paid_until"] = (datetime.now(timezone.utc) + timedelta(days=33)).isoformat().replace("+00:00", "Z")
            changed = True
    elif etype in ("invoice.paid", "invoice.payment_succeeded"):
        cust = obj.get("customer")
        # Renew any matching paid_sessions entry
        if cust:
            store = load_paid_sessions()
            for sid_key, entry in store.items():
                if entry.get("stripe_customer_id") == cust:
                    entry["paid"] = True
                    entry["paid_until"] = (datetime.now(timezone.utc) + timedelta(days=33)).isoformat().replace("+00:00", "Z")
            save_paid_sessions(store)
        sub = _find_by_customer(cust) if cust else None
        if sub:
            sub["paid"] = True
            sub["paid_until"] = (datetime.now(timezone.utc) + timedelta(days=33)).isoformat().replace("+00:00", "Z")
            changed = True
    elif etype in ("invoice.payment_failed", "customer.subscription.deleted"):
        cust = obj.get("customer")
        mark_session_unpaid_by_customer(cust or "")
        sub = _find_by_customer(cust) if cust else None
        if sub:
            sub["paid"] = False
            changed = True

    if changed:
        save_subscribers(subs)
    return jsonify({"ok": True})


@app.route("/api/unsubscribe", methods=["POST", "GET"])
def api_unsubscribe():
    token = request.args.get("token") or (request.get_json(silent=True) or {}).get("token", "")
    if not token:
        return jsonify({"ok": False, "error": "Missing token"}), 400
    subs = load_subscribers()
    found = None
    for s in subs:
        if s.get("unsubscribe_token") == token:
            s["active"] = False
            found = s
            break
    if not found:
        return jsonify({"ok": False, "error": "Unknown token"}), 404
    save_subscribers(subs)
    if request.method == "GET":
        return render_template("subscribe.html", unsubscribed=True)
    return jsonify({"ok": True})


# ── Subscriber API (admin) ──


@app.route("/api/subscribers", methods=["GET"])
def api_subscribers_list():
    return jsonify(load_subscribers())


@app.route("/api/subscribers/<sub_id>", methods=["DELETE"])
def api_subscribers_delete(sub_id):
    subs = load_subscribers()
    subs = [s for s in subs if s.get("id") != sub_id]
    save_subscribers(subs)
    return jsonify({"ok": True})


@app.route("/save_config", methods=["POST"])
def save_config_route():
    """Public endpoint: only user-facing search/notification fields.
    Admin-only credential fields are silently ignored unless caller is admin."""
    data = request.json or {}
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

    # Admin-only keys: ignored unless logged in as admin
    if _is_admin():
        if "sms_api_username" in data:
            config["sms_api_username"] = data.get("sms_api_username", "").strip()
        if "sms_api_password" in data:
            config["sms_api_password"] = data.get("sms_api_password", "").strip()
        if "ntfy_enabled" in data:
            config["ntfy_enabled"] = bool(data.get("ntfy_enabled"))
        if "ntfy_topic" in data:
            config["ntfy_topic"] = data.get("ntfy_topic", "").strip()
        if "ntfy_server" in data:
            config["ntfy_server"] = (data.get("ntfy_server") or "https://ntfy.sh").strip()
        for k in ("smtp_host", "smtp_user", "smtp_pass", "smtp_from"):
            if k in data:
                config[k] = (data.get(k) or "").strip()
        if "smtp_port" in data:
            try:
                config["smtp_port"] = int(data.get("smtp_port") or 587)
            except (TypeError, ValueError):
                config["smtp_port"] = 587
    save_config_file(config)
    return jsonify({"status": "ok"})


@app.route("/save_admin_config", methods=["POST"])
def save_admin_config():
    """Admin-only endpoint for credential / notification-channel fields."""
    data = request.json or {}
    config = load_config()
    if "sms_api_username" in data:
        config["sms_api_username"] = data.get("sms_api_username", "").strip()
    if "sms_api_password" in data:
        config["sms_api_password"] = data.get("sms_api_password", "").strip()
    if "ntfy_enabled" in data:
        config["ntfy_enabled"] = bool(data.get("ntfy_enabled"))
    if "ntfy_topic" in data:
        config["ntfy_topic"] = data.get("ntfy_topic", "").strip()
    if "ntfy_server" in data:
        config["ntfy_server"] = (data.get("ntfy_server") or "https://ntfy.sh").strip()
    for k in ("smtp_host", "smtp_user", "smtp_pass", "smtp_from"):
        if k in data:
            config[k] = (data.get(k) or "").strip()
    if "smtp_port" in data:
        try:
            config["smtp_port"] = int(data.get("smtp_port") or 587)
        except (TypeError, ValueError):
            config["smtp_port"] = 587
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
    # SMS fires if creds are present AND (legacy sms_to is set OR there are phone subscribers).
    _has_phone_subs = any(is_sub_paid(s) and s.get("phone") for s in load_subscribers())
    sms_configured = sms_enabled and sms_user and sms_pass and (bool(sms_to) or _has_phone_subs)

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
        # Collect all SMS recipients: legacy single sms_to + active subscribers
        sms_recipients = []
        if sms_to:
            sms_recipients.append(sms_to)
        for sub in load_subscribers():
            if is_sub_paid(sub) and sub.get("phone") and sub["phone"] not in sms_recipients:
                sms_recipients.append(sub["phone"])

        sms_results = []
        any_sms_ok = False
        for recipient in sms_recipients:
            try:
                r = send_sms(recipient, msg, sms_user, sms_pass)
            except Exception as e:
                app.logger.error("SMS send failed to %s: %s", recipient, e)
                r = {"ok": False, "error": str(e)}
            if r.get("ok"):
                any_sms_ok = True
            sms_results.append({
                "to": recipient,
                "ok": r.get("ok"),
                "status": r.get("status"),
                "from": r.get("from"),
                "error": r.get("error"),
                "data": (r.get("data") or "")[:200],
            })

        if any_sms_ok:
            any_sent_ok = True

        log = load_activity_log()
        log.append({
            "type": "sms_sent" if any_sms_ok else "sms_failed",
            "time": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "recipients": len(sms_recipients),
            "notified_count": len(to_notify),
            "results": sms_results[:10],
        })
        save_activity_log(log)

    # ── Email fan-out to subscribers with email ──
    email_recipients = [s for s in load_subscribers()
                        if is_sub_paid(s) and s.get("email")]
    if to_notify and email_recipients:
        msg_text = _build_message()
        email_results = []
        any_email_ok = False
        base_url = request.host_url.rstrip("/") if request else ""
        for sub in email_recipients:
            unsub_link = f"{base_url}/api/unsubscribe?token={sub.get('unsubscribe_token','')}"
            body = (
                f"{msg_text}\n\n"
                f"Boka direkt: https://fp.trafikverket.se/boka/ng\n\n"
                f"Avregistrera: {unsub_link}\n"
            )
            try:
                r = send_email(sub["email"], "Ledig provtid hittad!", body)
            except Exception as e:
                app.logger.error("Email send failed to %s: %s", sub["email"], e)
                r = {"ok": False, "error": str(e)}
            if r.get("ok"):
                any_email_ok = True
            email_results.append({"to": sub["email"], "ok": r.get("ok"), "error": r.get("error")})
        if any_email_ok:
            any_sent_ok = True
        log = load_activity_log()
        log.append({
            "type": "email_sent" if any_email_ok else "email_failed",
            "time": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "recipients": len(email_recipients),
            "notified_count": len(to_notify),
            "results": email_results[:10],
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
    # Live-läge krävs: bokning bakom betalvägg.
    if stripe_enabled() and not is_session_paid():
        return jsonify({
            "ok": False,
            "error": "live_required",
            "message": "Aktivera live-läge för att boka tider.",
        }), 402
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


@app.route("/api/verify_slot", methods=["POST"])
def api_verify_slot():
    """Re-query Trafikverket for a single location right before the user clicks
    Boka, to detect slots that have already been taken (the most common reason
    a found slot does not appear when the user lands on Trafikverket)."""
    if not auth_state["authenticated"]:
        return jsonify({"ok": False, "error": "Not authenticated"}), 401
    data = request.get_json(silent=True) or {}
    slot = data.get("slot") or {}
    location_id = slot.get("location_id")
    date = slot.get("date", "")
    time = slot.get("time", "")
    if not location_id or not date or not time:
        return jsonify({"ok": False, "error": "missing slot fields"}), 400

    config = load_config()
    ssn = config.get("swedish_ssn", "")
    exam_type = config.get("exam_type", "Körprov")
    licence_type = config.get("licence_type", "B")
    lp = LICENCE_PARAMS.get(licence_type, LICENCE_PARAMS["B"])
    exam_type_id = lp["exam_ids"].get(exam_type, EXAM_TYPE_IDS.get(exam_type, 12))

    fresh = _fetch_location(ssn, exam_type_id, location_id,
                            lp["licence_id"], lp["vehicle_type_id"])
    still_there = any(
        t.get("date") == date and t.get("time") == time for t in fresh
    )
    return jsonify({
        "ok": True,
        "still_available": still_there,
        "checked_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "alternatives_count": len(fresh),
    })


def _build_booking_session(config: dict) -> tuple[dict, dict]:
    ssn = config.get("swedish_ssn", "")
    exam_type = config.get("exam_type", "Körprov")
    licence_type = config.get("licence_type", "B")
    lp = LICENCE_PARAMS.get(licence_type, LICENCE_PARAMS["B"])
    exam_type_id = lp["exam_ids"].get(exam_type, EXAM_TYPE_IDS.get(exam_type, 12))
    booking_session = {
        "socialSecurityNumber": ssn,
        "licenceId": lp["licence_id"],
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
    }
    return booking_session, lp


@app.route("/api/book_slot", methods=["POST"])
def api_book_slot():
    """Claim a slot at Trafikverket via /create-reservation (15-min hold).

    After this returns ok=True the slot is reserved in the user's name on
    fp.trafikverket.se for 15 minutes; the user must complete payment there.
    """
    if not auth_state["authenticated"]:
        return jsonify({"ok": False, "error": "Not authenticated"}), 401

    data = request.get_json(silent=True) or {}
    slot = data.get("slot") or {}
    location_id = slot.get("location_id")
    date = slot.get("date", "")
    time = slot.get("time", "")
    if not location_id or not date or not time:
        return jsonify({"ok": False, "error": "missing slot fields"}), 400

    config = load_config()
    booking_session, lp = _build_booking_session(config)
    occasion_bundle_query = {
        "startDate": "1970-01-01T00:00:00.000Z",
        "searchedMonths": 0,
        "locationId": location_id,
        "nearbyLocationIds": [],
        "vehicleTypeId": lp["vehicle_type_id"],
        "tachographTypeId": 1,
        "occasionChoiceId": 1,
        "examinationTypeId": booking_session["examinationTypeId"],
    }

    try:
        r = tv_session.post(
            TV_BASE + "/occasion-bundles",
            json={"bookingSession": booking_session,
                  "occasionBundleQuery": occasion_bundle_query},
            timeout=15,
        )
        bundles_resp = r.json()
    except Exception as e:
        app.logger.error("book_slot occasion-bundles fetch failed: %s", e)
        return jsonify({"ok": False, "error": "trafikverket_unreachable"}), 502

    if bundles_resp.get("status") != 200:
        return jsonify({"ok": False, "error": "lookup_failed",
                        "data": bundles_resp.get("data")}), 502

    target_bundle = None
    for b in bundles_resp.get("data", {}).get("bundles", []):
        for o in b.get("occasions", []):
            if o.get("date") == date and o.get("time") == time:
                target_bundle = b
                break
        if target_bundle:
            break

    if not target_bundle:
        return jsonify({"ok": False, "error": "slot_gone",
                        "message": "Tiden är inte längre tillgänglig."}), 409

    try:
        rr = tv_session.post(
            TV_BASE + "/create-reservation",
            json={"bookingSession": booking_session,
                  "occasionBundle": target_bundle},
            timeout=20,
        )
    except Exception as e:
        app.logger.error("create-reservation request failed: %s", e)
        return jsonify({"ok": False, "error": "trafikverket_unreachable"}), 502

    try:
        result = rr.json()
    except Exception:
        app.logger.error("create-reservation non-JSON response: status=%s body=%s",
                          rr.status_code, (rr.text or "")[:300])
        return jsonify({"ok": False, "error": "trafikverket_invalid_response",
                        "status": rr.status_code}), 502

    envelope_status = result.get("status") if isinstance(result, dict) else None
    if rr.status_code != 200 or (envelope_status is not None and envelope_status != 200):
        app.logger.warning("create-reservation rejected: http=%s body=%s",
                            rr.status_code, str(result)[:400])
        return jsonify({"ok": False, "error": "create_reservation_failed",
                        "http_status": rr.status_code,
                        "tv_response": result}), 502

    log = load_activity_log()
    log.append({
        "type": "booked_with_trafikverket",
        "time": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "slot": slot,
    })
    save_activity_log(log)

    return jsonify({
        "ok": True,
        "message": ("Tiden är reserverad i ditt namn på Trafikverket "
                    "(15 minuter). Slutför betalningen där."),
        "reservation": result.get("data") if isinstance(result, dict) else result,
    })


@app.route("/api/book_diagnose", methods=["POST"])
def api_book_diagnose():
    """Probe Trafikverket for the user's current state so we can see what
    is blocking /create-reservation. Calls get-active-reservations,
    get-confirmed-examinations, and booking-hindrances and returns each
    raw response verbatim."""
    if not auth_state["authenticated"]:
        return jsonify({"ok": False, "error": "Not authenticated"}), 401

    config = load_config()
    booking_session, lp = _build_booking_session(config)

    def _post(slug: str, payload: dict) -> dict:
        try:
            r = tv_session.post(TV_BASE + "/" + slug, json=payload, timeout=15)
            try:
                body = r.json()
            except Exception:
                body = {"_non_json": (r.text or "")[:400]}
            return {"http_status": r.status_code, "body": body}
        except Exception as e:
            return {"error": str(e)}

    return jsonify({
        "ok": True,
        "active_reservations": _post("get-active-reservations", {}),
        "confirmed_examinations": _post("get-confirmed-examinations",
                                        {"licenceId": lp["licence_id"]}),
        "booking_hindrances": _post("booking-hindrances",
                                    {"bookingSession": booking_session}),
        "booking_session_used": booking_session,
    })


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
    body = request.get_json(silent=True) or {}
    to = (body.get("to") or "").strip() or config.get("sms_to", "")
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


@app.route("/api/email/test", methods=["POST"])
def api_email_test():
    """Send a test email to verify SMTP credentials."""
    body = request.get_json(silent=True) or {}
    to = (body.get("to") or "").strip()
    if not to:
        return jsonify({"ok": False, "error": "Ange mottagaradress"}), 400
    result = send_email(to, "Provbok test",
                        "Test från Provbokningsbevakning - e-post fungerar!")
    return jsonify(result)


@app.route("/api/sms/relay", methods=["POST"])
def api_sms_relay():
    """Forward an SMS request from a dev box to 46elks via this server.

    Authenticated with a shared bearer token (`SMS_RELAY_TOKEN` env). Uses
    the server's own `SMS_API_USERNAME` / `SMS_API_PASSWORD` credentials.
    """
    expected = (os.environ.get("SMS_RELAY_TOKEN") or "").strip()
    if not expected:
        return jsonify({"ok": False, "error": "relay disabled"}), 503
    auth_hdr = (request.headers.get("Authorization") or "").strip()
    token = auth_hdr[7:] if auth_hdr.lower().startswith("bearer ") else ""
    if not hmac.compare_digest(token, expected):
        return jsonify({"ok": False, "error": "unauthorized"}), 401

    body = request.get_json(silent=True) or {}
    to = (body.get("to") or "").strip()
    msg = (body.get("message") or "").strip()
    if not to or not msg:
        return jsonify({"ok": False, "error": "to and message required"}), 400

    cfg = load_config()
    sms_user = os.environ.get("SMS_API_USERNAME") or cfg.get("sms_api_username", "")
    sms_pass = os.environ.get("SMS_API_PASSWORD") or cfg.get("sms_api_password", "")
    if not sms_user or not sms_pass:
        return jsonify({"ok": False, "error": "server has no SMS credentials"}), 500

    # Temporarily clear SMS_RELAY_URL so the server actually calls 46elks
    # rather than recursing back to itself.
    saved = os.environ.pop("SMS_RELAY_URL", None)
    try:
        result = send_sms(to, msg, sms_user, sms_pass)
    finally:
        if saved is not None:
            os.environ["SMS_RELAY_URL"] = saved
    return jsonify(result)


@app.route("/api/config", methods=["GET"])
def api_config_get():
    """Return user-facing config fields (no admin secrets) for the mobile client."""
    cfg = load_config()
    public_keys = (
        "swedish_ssn", "licence_type", "exam_type", "locations",
        "date_from", "date_to", "sms_enabled", "sms_to",
    )
    out = {k: cfg.get(k, "" if k != "locations" else []) for k in public_keys}
    out["sms_enabled"] = bool(out.get("sms_enabled"))
    if not isinstance(out.get("locations"), list):
        out["locations"] = []
    return jsonify(out)


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
