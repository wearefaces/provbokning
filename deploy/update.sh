#!/usr/bin/env bash
# update.sh — pull latest code and restart the service. Run as root.
set -euo pipefail

APP_DIR="${PROVBOK_DIR:-/opt/provbok}/app"
VENV_DIR="${PROVBOK_DIR:-/opt/provbok}/venv"
USER_NAME="${PROVBOK_USER:-provbok}"

if [[ $EUID -ne 0 ]]; then
    echo "Run as root (sudo bash update.sh)" >&2
    exit 1
fi

echo "==> Pulling latest code"
sudo -u "$USER_NAME" git -C "$APP_DIR" pull --ff-only

echo "==> Updating dependencies"
"$VENV_DIR/bin/pip" install -q -r "$APP_DIR/requirements.txt"

# Re-install systemd unit in case it changed
install -m 0644 "$APP_DIR/deploy/provbok.service" /etc/systemd/system/provbok.service
systemctl daemon-reload

echo "==> Restarting service"
systemctl restart provbok

systemctl --no-pager --full status provbok | head -n 12
echo "==> Done"
