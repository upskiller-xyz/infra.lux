# Topologi A — VM (Scaleway Instance)

CPU-tjänsterna körs som Docker-containrar på en enda Scaleway-instans bakom nginx;
GPU-inferensen ligger på Modal (se [../modal/model_gpu/](../modal/model_gpu/)). Bilder
**pullas** via taggar i [../images.env](../images.env) — byggs aldrig på instansen.

Migrerad hit från `server_lux/deployment/` (Scaleway/Cloudflare-varianten) och
gjord pull-baserad.

## Innehåll

| Fil | Roll |
|---|---|
| `docker-compose.vm.yml` | stacken; `image:`-referenser från `../images.env` |
| `nginx.conf` | publik gateway, TLS bakom Cloudflare (Full strict) |
| `setup-vm.sh` | engångs-bootstrap: Docker + Compose + tooling |
| `setup-cloudflare.sh` | DNS A-record + SSL-läge + Origin-cert → `certs/` |
| `deploy-vm.sh` | registry-login + `pull` + `up -d` (rollback = byt tagg) |
| `certs/` | Cloudflare Origin Certificate (gitignorerad) |
| `fail2ban/` | banna scanner-IP:n (444/429) |

## Körordning (på instansen)

```bash
bash setup-vm.sh                       # en gång
cp ../envs/vm.env.example ../envs/vm.env && $EDITOR ../envs/vm.env
bash setup-cloudflare.sh               # DNS + TLS (en gång)
bash deploy-vm.sh --firewall           # pull + up
```

Uppdatera prod: ändra en tagg i `../images.env`, kör `bash deploy-vm.sh`.
