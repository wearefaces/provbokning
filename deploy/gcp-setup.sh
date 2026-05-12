#!/usr/bin/env bash
# Provbok — Google Cloud setup (run in Cloud Shell at https://shell.cloud.google.com)
#
# Creates an Always-Free e2-micro VM in us-west1 running Ubuntu 22.04,
# installs the app as a systemd service, opens port 5000, and prints the
# external IP. Optional: install Tailscale on the VM to bypass corporate
# proxies (recommended for accessing from a work laptop with Zscaler).
#
# Usage:
#   1. Open https://shell.cloud.google.com (logged in to the account that
#      owns the target project).
#   2. Clone this repo:
#        git clone https://github.com/wearefaces/provbokning.git
#        cd provbokning
#   3. Edit the variables below if needed, then run:
#        bash deploy/gcp-setup.sh
#
# Re-running is safe: VM creation will fail if the instance already exists,
# but firewall / API steps are idempotent.

set -euo pipefail

# ── CONFIG ───────────────────────────────────────────────────────────────────
PROJECT_ID="${PROJECT_ID:-}"      # e.g. "provboking" or "977496169830"
INSTANCE_NAME="${INSTANCE_NAME:-provbok}"
ZONE="${ZONE:-us-west1-a}"        # Always-Free regions: us-west1, us-central1, us-east1
MACHINE_TYPE="${MACHINE_TYPE:-e2-micro}"  # Always-Free eligible
DISK_SIZE_GB="${DISK_SIZE_GB:-30}"
IMAGE_FAMILY="${IMAGE_FAMILY:-ubuntu-2204-lts}"
IMAGE_PROJECT="${IMAGE_PROJECT:-ubuntu-os-cloud}"
REPO_URL="${REPO_URL:-https://github.com/wearefaces/provbokning.git}"
APP_USER="${APP_USER:-provbok}"
APP_PORT="${APP_PORT:-5000}"
# ─────────────────────────────────────────────────────────────────────────────

if [[ -z "$PROJECT_ID" ]]; then
  PROJECT_ID="$(gcloud config get-value project 2>/dev/null || true)"
fi
if [[ -z "$PROJECT_ID" ]]; then
  echo "ERROR: set PROJECT_ID env var or run 'gcloud config set project <id>' first." >&2
  exit 1
fi

echo "▶ Using project: $PROJECT_ID"
gcloud config set project "$PROJECT_ID" >/dev/null

echo "▶ Enabling Compute Engine API (may take a minute)…"
gcloud services enable compute.googleapis.com

echo "▶ Creating firewall rule for port $APP_PORT (if missing)…"
gcloud compute firewall-rules describe allow-provbok >/dev/null 2>&1 || \
  gcloud compute firewall-rules create allow-provbok \
    --allow=tcp:"$APP_PORT" \
    --target-tags=provbok \
    --description="Allow Provbok web UI"

# Startup script that runs on the VM as root the first time it boots.
STARTUP_SCRIPT=$(cat <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec > >(tee -a /var/log/provbok-startup.log) 2>&1
echo "[startup] \$(date) starting"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y python3 python3-pip python3-venv git ca-certificates curl

id -u $APP_USER >/dev/null 2>&1 || useradd -m -s /bin/bash $APP_USER

sudo -u $APP_USER bash <<'USER_EOF'
set -euo pipefail
cd \$HOME
if [[ ! -d provbokning ]]; then
  git clone $REPO_URL provbokning
fi
cd provbokning
python3 -m venv .venv
.venv/bin/pip install --upgrade pip
.venv/bin/pip install -r requirements.txt gunicorn
mkdir -p data
USER_EOF

# Persisted env file — admin fills in credentials after first boot via:
#   sudo nano /etc/provbok.env  (then: sudo systemctl restart provbok)
if [[ ! -f /etc/provbok.env ]]; then
  SECRET_KEY="\$(python3 -c 'import secrets;print(secrets.token_hex(32))')"
  cat > /etc/provbok.env <<ENV_EOF
# Fill in the values below, then: sudo systemctl restart provbok
SECRET_KEY=\$SECRET_KEY
COOKIE_SECURE=0
LOGIN_USER=admin
LOGIN_PASS=change-me-now
SMS_API_USERNAME=
SMS_API_PASSWORD=
DATA_DIR=/home/$APP_USER/provbokning/data
PORT=$APP_PORT
ENV_EOF
  chmod 600 /etc/provbok.env
fi

cat > /etc/systemd/system/provbok.service <<UNIT_EOF
[Unit]
Description=Provbok Trafikverket checker
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$APP_USER
WorkingDirectory=/home/$APP_USER/provbokning
EnvironmentFile=/etc/provbok.env
ExecStart=/home/$APP_USER/provbokning/.venv/bin/gunicorn --bind 0.0.0.0:$APP_PORT --workers 1 --threads 8 --timeout 120 web:app
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT_EOF

systemctl daemon-reload
systemctl enable --now provbok.service
echo "[startup] \$(date) done"
EOF
)

echo "▶ Creating VM '$INSTANCE_NAME' in $ZONE…"
gcloud compute instances create "$INSTANCE_NAME" \
  --zone="$ZONE" \
  --machine-type="$MACHINE_TYPE" \
  --image-family="$IMAGE_FAMILY" \
  --image-project="$IMAGE_PROJECT" \
  --boot-disk-size="${DISK_SIZE_GB}GB" \
  --boot-disk-type=pd-standard \
  --tags=provbok,http-server \
  --metadata-from-file=startup-script=<(echo "$STARTUP_SCRIPT")

EXTERNAL_IP="$(gcloud compute instances describe "$INSTANCE_NAME" --zone="$ZONE" \
  --format='get(networkInterfaces[0].accessConfigs[0].natIP)')"

cat <<NOTE

────────────────────────────────────────────────────────────────────────────
✅ VM '$INSTANCE_NAME' created. External IP: $EXTERNAL_IP

The startup script is now installing dependencies on the VM (≈2-3 min).
Watch progress with:
    gcloud compute ssh $INSTANCE_NAME --zone=$ZONE --command='sudo tail -f /var/log/provbok-startup.log'

When it finishes ("[startup] ... done"), set your secrets:
    gcloud compute ssh $INSTANCE_NAME --zone=$ZONE
    sudo nano /etc/provbok.env       # set LOGIN_USER, LOGIN_PASS, SMS_API_USERNAME, SMS_API_PASSWORD
    sudo systemctl restart provbok

Open the web UI:
    http://$EXTERNAL_IP:$APP_PORT

────────────────────────────────────────────────────────────────────────────
🛡  Recommended for work laptop with Zscaler: install Tailscale on the VM:
    gcloud compute ssh $INSTANCE_NAME --zone=$ZONE
    curl -fsSL https://tailscale.com/install.sh | sh
    sudo tailscale up
    # → click the URL printed, log in with your Tailscale account
    # → install Tailscale on your work laptop (same account)
    # → access via http://<tailscale-name>:$APP_PORT (no public IP needed)
    # → then close the public firewall: gcloud compute firewall-rules delete allow-provbok
────────────────────────────────────────────────────────────────────────────
NOTE
