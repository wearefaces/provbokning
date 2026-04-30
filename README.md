# Trafikverket Körkortsprov Checker

Monitors available driving test times (körprov / kunskapsprov) on Trafikverket.
Detects free times AND newly available slots from cancellations.

## Setup

```bash
cd ~/trafikverket_checker
pip install -r requirements.txt
```

Edit `config.json` with your details:

```json
{
    "swedish_ssn": "19900101-1234",
    "exam_type": "Körprov",
    "locations": ["Sollentuna", "Järfälla", "Farsta"],
    "check_interval_seconds": 300,
    "date_from": "2026-04-13",
    "date_to": "2026-12-31"
}
```

- **swedish_ssn** — Your personnummer (YYYYMMDD-XXXX)
- **exam_type** — `Körprov` (driving test) or `Kunskapsprov` (theory test)
- **locations** — Filter by city names (empty list = all locations)
- **check_interval_seconds** — How often to check in watch mode
- **date_from / date_to** — Date range to search within

## Usage

### One-time scan
```bash
python checker.py
```
Shows all available times. Run again to see what changed (new/cancelled slots).

### Continuous monitoring (watch mode)
```bash
python checker.py --watch
```
Checks periodically and highlights:
- **NEW times** (green) — likely from cancellations, now available for booking
- **Removed times** (red) — recently booked by someone else

### Filter by location
```bash
python checker.py --locations Sollentuna Järfälla
python checker.py --watch -l Farsta
```

### Override exam type
```bash
python checker.py --exam Kunskapsprov
```

## How it works

Uses the same API as `fp.trafikverket.se/boka/` to query available occasion
bundles across all test locations in Sweden. Compares each scan to a saved
snapshot to detect changes — new slots appearing means someone cancelled
their booking.

## Deploy on your own Linux VPS (e.g. Miss Hosting Cloud VPS)

The repo ships a one-shot installer that sets up a hardened systemd
service, an nginx reverse proxy, and a Let's Encrypt certificate. Tested
on Ubuntu 22.04 / 24.04 and Debian 12.

### One-time setup

1. SSH into the server as `root` (or any user with sudo).
2. Run:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/wearefaces/provbokning/main/deploy/install.sh \
       -o /tmp/install.sh
   sudo \
     PROVBOK_DOMAIN=provbok.example.se \
     PROVBOK_EMAIL=you@example.com \
     LOGIN_USER=you \
     LOGIN_PASS='a-strong-password' \
     SMS_API_USERNAME='<46elks user>' \
     SMS_API_PASSWORD='<46elks pass>' \
     bash /tmp/install.sh
   ```
3. Point an `A` record for `provbok.example.se` at the VPS's IP **before**
   running the script (Let's Encrypt needs to reach it on port 80).
4. Open `https://provbok.example.se`, sign in, then **Logga in med BankID**.

### What the script does

- Installs `python3`, `nginx`, `certbot`, `ufw`
- Creates an unprivileged `provbok` user
- Clones the repo to `/opt/provbok/app`, creates a venv at `/opt/provbok/venv`
- Writes secrets to `/etc/provbok.env` (mode `640`, root:provbok)
- Installs the [systemd unit](deploy/provbok.service) and starts gunicorn
  on `127.0.0.1:8080`
- Enables `ufw` and opens 22 / 80 / 443
- Configures the [nginx site](deploy/nginx.conf) and obtains a Let's Encrypt cert

### Updating after `git push`

```bash
sudo bash /opt/provbok/app/deploy/update.sh
```

### Useful commands

```bash
systemctl status provbok
journalctl -u provbok -f               # live logs
sudoedit /etc/provbok.env              # change secrets, then:
systemctl restart provbok
```

## Deploy online (Fly.io)

The Flask web UI can run as an always-on service so you don't need your
laptop on. Because the BankID session is held in memory, the app must
run as **a single instance with one worker** — autoscaling is disabled.

### One-time setup

1. Install the Fly CLI: <https://fly.io/docs/hands-on/install-flyctl/>
2. `fly auth login`
3. From the repo root:
   ```bash
   fly launch --no-deploy --copy-config --name <your-app-name>
   fly volumes create provbok_data --size 1 --region arn
   fly secrets set \
       LOGIN_USER=you \
       LOGIN_PASS='a-strong-password' \
       SECRET_KEY="$(python -c 'import secrets;print(secrets.token_hex(32))')" \
       COOKIE_SECURE=1 \
       SMS_API_USERNAME='<46elks user>' \
       SMS_API_PASSWORD='<46elks pass>'
   fly deploy
   ```
4. Open the printed `https://<your-app-name>.fly.dev` URL, sign in on the
   login page, then click **Logga in med BankID** and scan the QR with your
   BankID app.

### What the env vars do

| Variable | Purpose |
|---|---|
| `LOGIN_USER` / `LOGIN_PASS` | Credentials for the built-in login page. If unset, the site is open. |
| `SECRET_KEY` | Signs the session cookie. Set to a long random hex string in production so sessions survive restarts. |
| `COOKIE_SECURE` | Set to `1` when serving over HTTPS so the cookie is HTTPS-only. |
| `SMS_API_USERNAME` / `SMS_API_PASSWORD` | 46elks credentials. Override `config.json` and stay out of the git repo / volume. |
| `DATA_DIR` | Where runtime JSON state is written (defaults to `/data` in the container, mounted from the Fly volume). |
| `PORT` | Bind port (Fly sets this automatically). |

### Updating

```bash
git push                # update GitHub
fly deploy              # build + roll out a new container
```

### Run with Docker locally

```bash
docker build -t provbok .
docker run --rm -p 8080:8080 \
    -v "$PWD/data:/data" \
    -e DATA_DIR=/data \
    -e LOGIN_USER=you -e LOGIN_PASS=secret \
    -e SECRET_KEY=devkey \
    provbok
```

### Notes / caveats

- **Single user only.** The server holds one Trafikverket session at a time.
- **Persistent disk required.** Snapshots, reservations and activity log live
  in `DATA_DIR`. On Fly that is the `provbok_data` volume mounted at `/data`.
- **Outbound HTTPS to `fp.trafikverket.se` and `api.46elks.com` must be allowed**
  (true on Fly by default).
- **Free tier note:** Fly's free allowance changes over time. Check pricing
  before relying on it.

