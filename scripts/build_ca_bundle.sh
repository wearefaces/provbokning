#!/usr/bin/env bash
# Build certs/ca-bundle.pem combining:
#   - certifi's bundle (public CAs)
#   - any *.crt files in /usr/local/share/ca-certificates/ (corp CAs)
#   - the live cert chain presented for api.46elks.com (captures the
#     current Zscaler intermediate when corporate TLS interception is
#     active and the locally-installed root has rotated/mismatched)
#
# Usage:  ./scripts/build_ca_bundle.sh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p certs

CERTIFI=$(python -c 'import certifi; print(certifi.where())')
CHAIN=$(mktemp)
trap 'rm -f "$CHAIN"' EXIT

echo | openssl s_client -connect api.46elks.com:443 -servername api.46elks.com \
    -showcerts 2>/dev/null \
  | awk '/BEGIN CERT/,/END CERT/' > "$CHAIN" || true

{
    cat "$CERTIFI"
    # Skip ZscalerRoot.crt: when present and stale it triggers a chain that
    # OpenSSL prefers and then fails with "certificate signature failure".
    for f in /usr/local/share/ca-certificates/*.crt; do
        [[ -e "$f" ]] || continue
        case "$(basename "$f")" in
            ZscalerRoot.crt|ZscalerRoot.crt.crt) continue ;;
        esac
        cat "$f"
    done
    [[ -s "$CHAIN" ]] && cat "$CHAIN"
} > certs/ca-bundle.pem

echo "Built certs/ca-bundle.pem with $(grep -c 'BEGIN CERT' certs/ca-bundle.pem) certs."
