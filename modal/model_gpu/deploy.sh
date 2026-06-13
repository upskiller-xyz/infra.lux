#!/usr/bin/env bash
# Deploya GPU-inferensen (upskiller-model) till Modal, oberoende av CPU-topologierna.
#
# Källkoden bor i server_model — detta skript checkar ut MODEL_REF och kör
# `modal deploy -m modal_app.app` därifrån. Pinnad ref + skalning i model.env.
#
# Prereqs: `modal` CLI inloggad (`modal token set ...`), git.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# shellcheck disable=SC1091
set -a; source model.env; set +a
: "${MODEL_REF:?set MODEL_REF in model.env}"
: "${SERVER_MODEL_DIR:?set SERVER_MODEL_DIR in model.env}"

if [[ ! -d "$SERVER_MODEL_DIR/modal_app" ]]; then
  echo "server_model not found at $SERVER_MODEL_DIR (no modal_app/)." >&2
  echo "Set SERVER_MODEL_DIR in model.env, or clone upskiller-xyz/server_model there." >&2
  exit 1
fi

echo "Deploying upskiller-model from ${SERVER_MODEL_DIR} @ ${MODEL_REF}"
git -C "$SERVER_MODEL_DIR" fetch --tags --quiet
git -C "$SERVER_MODEL_DIR" checkout --quiet "$MODEL_REF"

# `modal deploy` must run from the repo root so `modal_app.app` and `src` resolve.
( cd "$SERVER_MODEL_DIR" && modal deploy -m modal_app.app )

echo "Done. Point consumers' MODEL_SERVICE_URL at the printed *.modal.run host."
