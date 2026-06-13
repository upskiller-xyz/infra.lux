#!/usr/bin/env bash
set -euo pipefail

# Topologi A (VM): pull-baserad deploy på en Scaleway Instance.
#
# Skillnad mot gamla deploy-scaleway.sh: vi KLONAR och BYGGER inte källkod på
# instansen längre — vi loggar in i registret och PULLAR de taggar som pinnats
# i images.env, sen `up -d`. Rollback = ändra tagg i images.env, kör om.
#
# Prereqs på instansen: docker + compose v2 (kör setup-vm.sh en gång först).
#
# Usage:
#   bash deploy-vm.sh [--firewall]
#     --firewall   konfigurera ufw (släpp endast 22/80/443)

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; NC='\033[0m'

SETUP_FIREWALL=false
for arg in "$@"; do
  case $arg in
    --firewall) SETUP_FIREWALL=true ;;
    *) echo "Unknown option: $arg"; echo "Usage: bash deploy-vm.sh [--firewall]"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

COMPOSE_FILE="docker-compose.vm.yml"
IMAGES_ENV="../images.env"
RUNTIME_ENV="../envs/vm.env"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Server Lux — VM deployment (pull images, Modal inference)${NC}"
echo -e "${GREEN}========================================${NC}"

# ── 1. Env-filer ──────────────────────────────────────────────────────────────
[[ -f "$IMAGES_ENV" ]]  || { echo -e "${RED}Missing $IMAGES_ENV${NC}"; exit 1; }
if [[ ! -f "$RUNTIME_ENV" ]]; then
  echo -e "${RED}Missing $RUNTIME_ENV${NC}. Copy the template and fill it in:"
  echo "  cp ../envs/vm.env.example $RUNTIME_ENV && \$EDITOR $RUNTIME_ENV"
  exit 1
fi
# shellcheck disable=SC1090
set -a; source "$IMAGES_ENV"; source "$RUNTIME_ENV"; set +a

# Sanity-check Modal-wiringen tidigt (innan vi drar upp stacken).
if [[ "${MODEL_SERVICE_URL:-}" == *".modal.run"* ]]; then
  if [[ -z "${MODAL_KEY:-}" || -z "${MODAL_SECRET:-}" ]]; then
    echo -e "${RED}MODEL_SERVICE_URL is a Modal URL but MODAL_KEY/MODAL_SECRET are unset${NC}"
    exit 1
  fi
  echo -e "${BLUE}Inference: Modal${NC} ($MODEL_SERVICE_URL)"
else
  echo -e "${YELLOW}Inference: MODEL_SERVICE_URL is not a *.modal.run URL — no proxy-auth attached.${NC}"
fi

# ── 1b. TLS: Cloudflare Origin Certificate ────────────────────────────────────
mkdir -p certs
if [[ ! -f certs/origin.pem || ! -f certs/origin.key ]]; then
  echo -e "${RED}Missing TLS cert${NC} (certs/origin.pem + certs/origin.key)."
  echo "Run setup-cloudflare.sh to auto-issue, or drop the files in manually."
  exit 1
fi

# ── 2. Registry-login (privata bilder) ────────────────────────────────────────
# Scaleway-registret kräver login för pull av privata bilder. SCW_SECRET_KEY i vm.env.
if [[ -n "${SCW_SECRET_KEY:-}" ]]; then
  echo -e "${BLUE}Logging in to ${REGISTRY}...${NC}"
  echo "$SCW_SECRET_KEY" | docker login "${REGISTRY}" -u "${SCW_REGISTRY_USER:-nologin}" --password-stdin
fi

# ── 3. Optional firewall: expose only SSH + HTTP(S) ──────────────────────────
if [[ "$SETUP_FIREWALL" == true ]]; then
  echo -e "${BLUE}Configuring ufw (allow 22/80/443, deny the rest)...${NC}"
  sudo ufw allow 22/tcp; sudo ufw allow 80/tcp; sudo ufw allow 443/tcp
  sudo ufw --force enable
fi

# ── 4. Pull pinned tags + bring up the stack ─────────────────────────────────
COMPOSE=(docker compose -f "$COMPOSE_FILE" --env-file "$IMAGES_ENV" --env-file "$RUNTIME_ENV")
echo -e "${BLUE}Pulling images (tags from images.env)...${NC}"
"${COMPOSE[@]}" pull
echo -e "${BLUE}Starting stack...${NC}"
"${COMPOSE[@]}" up -d

echo -e "${GREEN}Done.${NC} Public entrypoint via nginx (80/443)."
"${COMPOSE[@]}" ps
