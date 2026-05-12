#!/usr/bin/env bash
# setup-stripe.sh — add Stripe Checkout credentials to /etc/provbok.env
# Run on the VM as root or with sudo.
#
# Prerequisites:
#   1. Create a Stripe account (https://dashboard.stripe.com/register)
#   2. Create a Product → Price (Recurring, SEK 99/month) and copy the price_xxx ID
#   3. Grab the Secret key (sk_live_...) from https://dashboard.stripe.com/apikeys
#   4. Add a webhook endpoint at
#      https://provbok.8-229-124-88.nip.io/api/stripe/webhook
#      listening for: checkout.session.completed, invoice.payment_succeeded,
#      invoice.payment_failed, customer.subscription.deleted
#      Copy the signing secret (whsec_...)
#
set -euo pipefail

ENV_FILE=/etc/provbok.env
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found" >&2
  exit 1
fi

read -rsp "Stripe Secret key (sk_live_... or sk_test_...): " SK; echo
read -rp  "Stripe Price ID (price_...): " PID
read -rsp "Stripe Webhook signing secret (whsec_...): " WHS; echo
read -rp  "Price label shown to subscribers [99 kr/mån]: " LABEL
LABEL="${LABEL:-99 kr/mån}"

sed -i.bak '/^STRIPE_SECRET_KEY=/d;/^STRIPE_PRICE_ID=/d;/^STRIPE_WEBHOOK_SECRET=/d;/^SUBSCRIPTION_PRICE_LABEL=/d' "$ENV_FILE"
{
  echo "STRIPE_SECRET_KEY=$SK"
  echo "STRIPE_PRICE_ID=$PID"
  echo "STRIPE_WEBHOOK_SECRET=$WHS"
  echo "SUBSCRIPTION_PRICE_LABEL=$LABEL"
} >> "$ENV_FILE"

chmod 600 "$ENV_FILE"
systemctl restart provbok
echo "Stripe configured. Visit https://provbok.8-229-124-88.nip.io/ to test the checkout flow."
