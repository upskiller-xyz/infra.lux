#!/usr/bin/env bash
set -euo pipefail

# Automate the Cloudflare setup for the VM deployment. Idempotent — safe to re-run.
#   1. Upserts a proxied A record  DOMAIN -> this instance's public IP
#   2. Sets the zone SSL/TLS mode to Full (strict)
#   3. Issues a Cloudflare Origin Certificate and writes certs/origin.{pem,key}
#
# Reads config from ../envs/vm.env:
#   CF_API_TOKEN     API token with Zone:DNS:Edit + Zone Settings:Edit  (required)
#   CF_ZONE_ID       the zone id for your domain                         (required)
#   DOMAIN           the record to create, e.g. api.yourdomain.com       (required)
#   SERVER_IP        public IP (optional; auto-detected if unset)
#   CF_ORIGIN_CA_KEY Origin CA key (User Profile ▶ API Tokens ▶ Origin CA Key).
#                    Required only for step 3 (cert issuance).
#
# Usage:  bash setup-cloudflare.sh        (run once, before deploy-vm.sh)

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; NC='\033[0m'
API="https://api.cloudflare.com/client/v4"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

command -v jq >/dev/null   || { echo -e "${RED}jq not found${NC} — run setup-vm.sh first."; exit 1; }
command -v curl >/dev/null || { echo -e "${RED}curl not found${NC}."; exit 1; }

ENV_FILE="../envs/vm.env"
[[ -f "$ENV_FILE" ]] || { echo -e "${RED}Missing $ENV_FILE${NC} (cp ../envs/vm.env.example $ENV_FILE)"; exit 1; }
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

: "${CF_API_TOKEN:?Set CF_API_TOKEN in $ENV_FILE}"
: "${CF_ZONE_ID:?Set CF_ZONE_ID in $ENV_FILE}"
: "${DOMAIN:?Set DOMAIN in $ENV_FILE}"

# Abort with the Cloudflare error if a call did not succeed.
cf_ok() { # <json>
  if [[ "$(echo "$1" | jq -r '.success')" != "true" ]]; then
    echo -e "${RED}Cloudflare API error:${NC}"; echo "$1" | jq -r '.errors'; exit 1
  fi
}

# ── 1. DNS: upsert a proxied A record ────────────────────────────────────────
SERVER_IP="${SERVER_IP:-$(curl -fsS https://api.ipify.org)}"
echo -e "${BLUE}DNS:${NC} $DOMAIN -> $SERVER_IP (proxied)"
record_payload=$(jq -nc --arg name "$DOMAIN" --arg ip "$SERVER_IP" \
  '{type:"A", name:$name, content:$ip, proxied:true, ttl:1}')

existing=$(curl -fsS -H "Authorization: Bearer $CF_API_TOKEN" \
  "$API/zones/$CF_ZONE_ID/dns_records?type=A&name=$DOMAIN")
cf_ok "$existing"
rec_id=$(echo "$existing" | jq -r '.result[0].id // empty')

if [[ -n "$rec_id" ]]; then
  resp=$(curl -fsS -X PUT -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
    "$API/zones/$CF_ZONE_ID/dns_records/$rec_id" --data "$record_payload")
else
  resp=$(curl -fsS -X POST -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
    "$API/zones/$CF_ZONE_ID/dns_records" --data "$record_payload")
fi
cf_ok "$resp"
echo -e "  ${GREEN}✓ A record set${NC}"

# ── 2. SSL/TLS mode: Full (strict) ───────────────────────────────────────────
echo -e "${BLUE}SSL/TLS mode:${NC} strict"
resp=$(curl -fsS -X PATCH -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
  "$API/zones/$CF_ZONE_ID/settings/ssl" --data '{"value":"strict"}')
cf_ok "$resp"
echo -e "  ${GREEN}✓ Full (strict)${NC}"

# ── 3. Origin Certificate (skip if one already exists) ───────────────────────
if [[ -f certs/origin.pem && -f certs/origin.key ]]; then
  echo -e "${YELLOW}Origin cert already present in certs/ — skipping issuance.${NC}"
elif [[ -z "${CF_ORIGIN_CA_KEY:-}" ]]; then
  echo -e "${YELLOW}CF_ORIGIN_CA_KEY not set — skipping cert issuance.${NC}"
  echo "  Set it in $ENV_FILE to auto-issue, or drop certs/origin.{pem,key} in manually."
else
  echo -e "${BLUE}Origin cert:${NC} issuing for $DOMAIN"
  mkdir -p certs
  openssl req -new -newkey rsa:2048 -nodes \
    -keyout certs/origin.key -out /tmp/origin.csr -subj "/CN=$DOMAIN" 2>/dev/null
  cert_payload=$(jq -nc --arg csr "$(cat /tmp/origin.csr)" --arg h "$DOMAIN" \
    '{hostnames:[$h], requested_validity:5475, request_type:"origin-rsa", csr:$csr}')
  resp=$(curl -fsS -X POST -H "X-Auth-User-Service-Key: $CF_ORIGIN_CA_KEY" -H "Content-Type: application/json" \
    "$API/certificates" --data "$cert_payload")
  cf_ok "$resp"
  echo "$resp" | jq -r '.result.certificate' > certs/origin.pem
  chmod 600 certs/origin.key
  rm -f /tmp/origin.csr
  echo -e "  ${GREEN}✓ certs/origin.pem + origin.key written${NC} (valid ~15y)"
fi

echo -e "${GREEN}Cloudflare setup done.${NC} Next: bash deploy-vm.sh --firewall"
