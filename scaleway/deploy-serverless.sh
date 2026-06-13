#!/usr/bin/env bash
set -euo pipefail

# Topologi B — skapa/uppdatera Scaleway Serverless Container för combined CPU-stacken.
# Idempotent: skapar namespace + container om de saknas, annars uppdaterar + deployar.
#
# Prereqs: `scw` CLI installerat. Imagen måste finnas i lux-nsp (se Dockerfile/README).
# Usage:  bash deploy-serverless.sh
#
# OBS: verifiera scw-flaggor mot din CLI-version (`scw container container create -h`).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ENV_FILE="scaleway.env"
[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE (cp scaleway.env.example $ENV_FILE)"; exit 1; }
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

: "${CONTAINER_IMAGE:?}"; : "${MODEL_SERVICE_URL:?}"; : "${MODAL_KEY:?}"; : "${MODAL_SECRET:?}"
NS_NAME="${SCW_NAMESPACE_NAME:-lux-cpu}"
NAME="${CONTAINER_NAME:-cpu-pipeline}"

# ── Namespace (skapa om saknas) ───────────────────────────────────────────────
NS_ID=$(scw container namespace list name="$NS_NAME" -o json 2>/dev/null | jq -r '.[0].id // empty')
if [[ -z "$NS_ID" ]]; then
  echo "Creating namespace $NS_NAME..."
  NS_ID=$(scw container namespace create name="$NS_NAME" -o json | jq -r '.id')
fi
echo "Namespace: $NS_ID"

# ── Gemensamma argument ───────────────────────────────────────────────────────
COMMON=(
  port="${CONTAINER_PORT:-8080}"
  cpu-limit="${CONTAINER_CPU_LIMIT:-2000}"
  memory-limit="${CONTAINER_MEMORY_LIMIT:-4096}"
  min-scale="${MIN_SCALE:-1}"
  max-scale="${MAX_SCALE:-5}"
  registry-image="$CONTAINER_IMAGE"
  environment-variables.MODEL_SERVICE_URL="$MODEL_SERVICE_URL"
  environment-variables.AUTH_TYPE="${AUTH_TYPE:-none}"
  secret-environment-variables.MODAL_KEY="$MODAL_KEY"
  secret-environment-variables.MODAL_SECRET="$MODAL_SECRET"
)

# ── Skapa eller uppdatera ─────────────────────────────────────────────────────
CID=$(scw container container list namespace-id="$NS_ID" name="$NAME" -o json 2>/dev/null | jq -r '.[0].id // empty')
if [[ -z "$CID" ]]; then
  echo "Creating container $NAME..."
  CID=$(scw container container create namespace-id="$NS_ID" name="$NAME" "${COMMON[@]}" -o json | jq -r '.id')
else
  echo "Updating container $NAME ($CID)..."
  scw container container update "$CID" "${COMMON[@]}" >/dev/null
fi

echo "Deploying $CID..."
scw container container deploy "$CID" >/dev/null
ENDPOINT=$(scw container container get "$CID" -o json | jq -r '.domain_name // empty')
echo "Done. Endpoint: https://${ENDPOINT}"
echo "Mät med:  python ../modal/cpu_pipeline/measure.py --url https://${ENDPOINT} --path /apispec.json"
