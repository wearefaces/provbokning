#!/usr/bin/env bash
# setup-smtp.sh — interactively add SMTP credentials to /etc/provbok.env
# Run on the VM as root or with sudo.
#
# Recommended provider: Gmail with an App Password
#   1. Enable 2-Step Verification on the Google account
#   2. Go to https://myaccount.google.com/apppasswords
#   3. Create an app password called "provbok" and copy the 16-char value
#
set -euo pipefail

ENV_FILE=/etc/provbok.env
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found" >&2
  exit 1
fi

read -rp "SMTP host [smtp.gmail.com]: " HOST
HOST="${HOST:-smtp.gmail.com}"
read -rp "SMTP port [587]: " PORT
PORT="${PORT:-587}"
read -rp "SMTP user (full Gmail address): " USER
read -rsp "SMTP app password (input hidden): " PASS
echo
read -rp "From address [$USER]: " FROM
FROM="${FROM:-$USER}"

# Remove old SMTP_* lines, then append fresh values
sed -i.bak '/^SMTP_HOST=/d;/^SMTP_PORT=/d;/^SMTP_USER=/d;/^SMTP_PASS=/d;/^SMTP_FROM=/d' "$ENV_FILE"
{
  echo "SMTP_HOST=$HOST"
  echo "SMTP_PORT=$PORT"
  echo "SMTP_USER=$USER"
  echo "SMTP_PASS=$PASS"
  echo "SMTP_FROM=$FROM"
} >> "$ENV_FILE"

chmod 600 "$ENV_FILE"
systemctl restart provbok
echo "SMTP configured. Test via the admin UI → e-post → 'Skicka test'."
