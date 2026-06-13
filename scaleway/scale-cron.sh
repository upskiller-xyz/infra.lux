#!/usr/bin/env bash
set -euo pipefail

# Topologi B — dygns-skalning. Sätter min-scale på serverless-containern.
# Scaleway saknar inbyggd tidsbaserad min-scale, så en cron kör detta:
#   08:00  ->  scale-cron.sh up     (min-scale=1, varm dagtid)
#   22:00  ->  scale-cron.sh down   (min-scale=0, scale-to-zero natt)
#
# Usage:  bash scale-cron.sh up|down
#
# Schemaläggning (välj ett):
#   - GitHub Actions scheduled workflow (rek.) — se .github/workflows/scale-cron.yml,
#     SCW_*-secrets finns redan i org:en.
#   - Scaleway Serverless Job/Cron som kör detta skript.

ACTION="${1:-}"
case "$ACTION" in
  up)   MIN_SCALE=1 ;;
  down) MIN_SCALE=0 ;;
  *) echo "Usage: $0 up|down"; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
# I CI sätts SCW_*/namn via env; lokalt läs scaleway.env om den finns.
[[ -f scaleway.env ]] && { set -a; source scaleway.env; set +a; }

NS_NAME="${SCW_NAMESPACE_NAME:-lux-cpu}"
NAME="${CONTAINER_NAME:-cpu-pipeline}"

NS_ID=$(scw container namespace list name="$NS_NAME" -o json | jq -r '.[0].id // empty')
CID=$(scw container container list namespace-id="$NS_ID" name="$NAME" -o json | jq -r '.[0].id // empty')
[[ -n "$CID" ]] || { echo "Container $NAME not found"; exit 1; }

echo "Setting min-scale=$MIN_SCALE on $NAME ($CID)..."
scw container container update "$CID" min-scale="$MIN_SCALE" >/dev/null
scw container container deploy "$CID" >/dev/null
echo "Done ($ACTION)."
