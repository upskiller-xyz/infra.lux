#!/usr/bin/env bash
set -euo pipefail

# Cloudflare Tunnel för VM-deployen. Idempotent — kör om så ofta du vill.
#
# Instansen publicerar inga portar: cloudflared (i compose-stacken) ringer UT
# till Cloudflare, och DOMAIN pekar på tunneln i stället för på instansens IP.
# Skannrar som går direkt på IP:n når ingenting.
#
# Två körningar (inget avbrott vid bytet):
#   1. bash setup-cloudflare.sh   skapar tunneln + ingress, skriver TUNNEL_TOKEN
#                                 till ../envs/vm.env. DNS rörs inte än.
#      bash deploy-vm.sh          startar cloudflared — tunneln blir "healthy".
#   2. bash setup-cloudflare.sh   ser att tunneln är uppe och flyttar DOMAIN
#                                 till tunneln (proxied CNAME).
#
# Läser ../envs/vm.env:
#   CF_API_TOKEN   token med Account:Cloudflare Tunnel:Edit + Zone:DNS:Edit  (krävs)
#   CF_ACCOUNT_ID  konto-id                                                  (krävs)
#   CF_ZONE_ID     zon-id för domänen                                        (krävs)
#   DOMAIN         t.ex. lux-api.upskiller.xyz                               (krävs)
#   TUNNEL_NAME    valfritt, standard "lux-gateway"

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; NC='\033[0m'
API="https://api.cloudflare.com/client/v4"
# nginx på det interna edge-nätet (se docker-compose.vm.yml).
ORIGIN_SERVICE="http://lux-gateway:8080"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

command -v jq >/dev/null   || { echo -e "${RED}jq not found${NC} — run setup-vm.sh first."; exit 1; }
command -v curl >/dev/null || { echo -e "${RED}curl not found${NC}."; exit 1; }

ENV_FILE="../envs/vm.env"
[[ -f "$ENV_FILE" ]] || { echo -e "${RED}Missing $ENV_FILE${NC} (cp ../envs/vm.env.example $ENV_FILE)"; exit 1; }
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

: "${CF_API_TOKEN:?Set CF_API_TOKEN in $ENV_FILE}"
: "${CF_ACCOUNT_ID:?Set CF_ACCOUNT_ID in $ENV_FILE}"
: "${CF_ZONE_ID:?Set CF_ZONE_ID in $ENV_FILE}"
: "${DOMAIN:?Set DOMAIN in $ENV_FILE}"
TUNNEL_NAME="${TUNNEL_NAME:-lux-gateway}"

# Kör ett API-anrop och avbryt med Cloudflares fel om det inte lyckades.
cf() { # <method> <path> [json]
  local resp
  if [[ $# -ge 3 ]]; then
    resp=$(curl -sS -X "$1" -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
      "$API$2" --data "$3")
  else
    resp=$(curl -sS -X "$1" -H "Authorization: Bearer $CF_API_TOKEN" "$API$2")
  fi
  if [[ "$(echo "$resp" | jq -r '.success')" != "true" ]]; then
    echo -e "${RED}Cloudflare API error ($1 $2):${NC}" >&2; echo "$resp" | jq -r '.errors' >&2; exit 1
  fi
  echo "$resp"
}

# Sätt KEY=VALUE i env-filen utan att skriva ut värdet.
upsert_env() { # <key> <value>
  local tmp; tmp=$(mktemp)
  grep -v "^$1=" "$ENV_FILE" > "$tmp" || true
  printf '%s=%s\n' "$1" "$2" >> "$tmp"
  cat "$tmp" > "$ENV_FILE"; rm -f "$tmp"
  chmod 600 "$ENV_FILE"
}

ACCOUNT="/accounts/$CF_ACCOUNT_ID/cfd_tunnel"

# ── 1. Tunnel (fjärrstyrd: ingress-reglerna ligger i Cloudflare) ─────────────
echo -e "${BLUE}Tunnel:${NC} $TUNNEL_NAME"
tunnel_id=$(cf GET "$ACCOUNT?name=$TUNNEL_NAME&is_deleted=false" | jq -r '.result[0].id // empty')
if [[ -z "$tunnel_id" ]]; then
  tunnel_id=$(cf POST "$ACCOUNT" "$(jq -nc --arg n "$TUNNEL_NAME" '{name:$n, config_src:"cloudflare"}')" \
    | jq -r '.result.id')
  echo -e "  ${GREEN}✓ created${NC}"
else
  echo -e "  ${GREEN}✓ exists${NC}"
fi

# ── 2. Ingress: DOMAIN → nginx, allt annat 404 ───────────────────────────────
ingress=$(jq -nc --arg h "$DOMAIN" --arg s "$ORIGIN_SERVICE" '{config:{ingress:[
  {hostname:$h, service:$s, originRequest:{connectTimeout:10, keepAliveTimeout:90}},
  {service:"http_status:404"}]}}')
cf PUT "$ACCOUNT/$tunnel_id/configurations" "$ingress" > /dev/null
echo -e "  ${GREEN}✓ ingress${NC} $DOMAIN → $ORIGIN_SERVICE"

# ── 3. Token till vm.env (skrivs aldrig ut) ──────────────────────────────────
token=$(cf GET "$ACCOUNT/$tunnel_id/token" | jq -r '.result')
upsert_env TUNNEL_TOKEN "$token"
unset token
echo -e "  ${GREEN}✓ TUNNEL_TOKEN${NC} written to $ENV_FILE"

# ── 4. DNS: flytta DOMAIN till tunneln — bara när tunneln är uppe ────────────
status=$(cf GET "$ACCOUNT/$tunnel_id" | jq -r '.result.status')
if [[ "$status" != "healthy" ]]; then
  echo -e "${YELLOW}Tunnel status: $status${NC} — DNS is unchanged."
  echo "  Next: bash deploy-vm.sh   then run this script again to switch DNS."
  exit 0
fi

target="$tunnel_id.cfargotunnel.com"
record=$(jq -nc --arg n "$DOMAIN" --arg c "$target" '{type:"CNAME", name:$n, content:$c, proxied:true, ttl:1}')
existing=$(cf GET "/zones/$CF_ZONE_ID/dns_records?name=$DOMAIN")
rec_id=$(echo "$existing" | jq -r '.result[0].id // empty')
rec_content=$(echo "$existing" | jq -r '.result[0].content // empty')
if [[ "$rec_content" == "$target" ]]; then
  echo -e "${GREEN}✓ DNS already points to the tunnel${NC}"
elif [[ -n "$rec_id" ]]; then
  cf PUT "/zones/$CF_ZONE_ID/dns_records/$rec_id" "$record" > /dev/null
  echo -e "${GREEN}✓ DNS${NC} $DOMAIN → tunnel (was $(echo "$existing" | jq -r '.result[0].type'))"
else
  cf POST "/zones/$CF_ZONE_ID/dns_records" "$record" > /dev/null
  echo -e "${GREEN}✓ DNS${NC} $DOMAIN → tunnel"
fi

echo -e "${GREEN}Cloudflare Tunnel ready.${NC} Close 80/443 in the Scaleway security group (see README)."
