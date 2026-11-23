# Topologi A — VM (Scaleway Instance)

CPU-tjänsterna körs som Docker-containrar på en enda Scaleway-instans bakom nginx och
en Cloudflare Tunnel;
GPU-inferensen ligger på Modal (se [../modal/model_gpu/](../modal/model_gpu/)). Bilder
**pullas** via taggar i [../images.env](../images.env) — byggs aldrig på instansen.

Migrerad hit från `server_lux/deployment/` (Scaleway/Cloudflare-varianten) och
gjord pull-baserad.

## Innehåll

| Fil | Roll |
|---|---|
| `docker-compose.vm.yml` | stacken; `image:`-referenser från `../images.env` |
| `nginx.conf` | intern gateway (rate limiting, routing); nås bara via tunneln |
| `setup-vm.sh` | engångs-bootstrap: Docker + Compose + tooling |
| `setup-cloudflare.sh` | Cloudflare Tunnel + ingress + `TUNNEL_TOKEN`, sedan DNS → tunneln |
| `deploy-vm.sh` | registry-login + `pull` + `up -d` (rollback = byt tagg) |

## Nätverk

Ingen tjänst publicerar en host-port. `cloudflared` ringer ut till Cloudflare och
tar emot trafiken för `DOMAIN`; instansens IP har bara SSH öppet. Skannrar som går
direkt på IP:n når ingenting, och TLS sköts av Cloudflares edge.

```
internet ─▶ Cloudflare edge ══tunnel══▶ cloudflared ─▶ nginx:8080 ─▶ server-lux
```

Stäng också 80/443 i instansens **Scaleway security group** (inbound: bara 22, gärna
från en känd IP). ufw räcker inte ensamt: Docker skriver sina iptables-regler före
ufw:s.

## Körordning (på instansen)

```bash
bash setup-vm.sh                       # en gång
cp ../envs/vm.env.example ../envs/vm.env && $EDITOR ../envs/vm.env
bash setup-cloudflare.sh               # tunnel + TUNNEL_TOKEN (DNS orörd)
bash deploy-vm.sh --firewall           # pull + up, startar cloudflared
bash setup-cloudflare.sh               # tunneln är uppe → DNS flyttas dit
```

Uppdatera prod: ändra en tagg i `../images.env`, kör `bash deploy-vm.sh`.

## Migrering från publika portar

Kör stegen ovan i ordning. API:t svarar via den gamla A-posten tills sista steget
flyttar DNS, så bytet sker utan avbrott. Efteråt: stäng 80/443 i security group,
byt gärna instansens publika IP (den gamla finns i skannerlistor), och ta bort
`certs/` på instansen.
