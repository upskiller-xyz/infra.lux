# Topologi B — Scaleway Serverless Containers

CPU-stacken (server-lux + encoder/obstruction/merger/stats) körs som **EN Scaleway
Serverless Container** som autoskalar; GPU-inferens via den fristående
[model_gpu](../model_gpu/)-deployen. En cron justerar `min-scale` dag/natt.

## Upplägg

Samma combined-stack som [topologi C](../modal/cpu_pipeline/), men Scaleway pullar
en **registry-image** (kan inte bygga från lokal källa som Modal). Därför en
**multi-stage Dockerfile** som återanvänder de redan byggda tjänst-imagernas
`src/` från `lux-nsp` och installerar union-deps en gång — supervisor kör de fem
gunicorn-processerna, lux exponeras på `:8080` (Scaleways enda port).

**Varför EN container** (inte fem separata serverless containers): matchar
"minst 1 instans"-modellen, ger **en** cold start och localhost-anrop i stället
för N cold starts + N nätverkshopp. (Fem separata = mer drift, fler cold starts.)

```
internet ─▶ Scaleway Serverless Container (combined CPU-stack)
              └─▶ MODEL_SERVICE_URL ─▶ Modal GPU (proxy-auth)
            min-scale: 1 (dag) / 0 (natt)  ← cron
```

## Dygns-skalning (cron)

Scaleway har **ingen** inbyggd tidsbaserad `min-scale`. En cron kör
[scale-cron.sh](scale-cron.sh) `up`/`down` som sätter `min-scale` via `scw`:

- **08:00 → `min-scale=1`** (varm dagtid, ingen cold start för användarna)
- **22:00 → `min-scale=0`** (scale-to-zero natt; cold start men få användare)

Två sätt att schemalägga (välj ett):
- **GitHub Actions scheduled workflow** (rek.) — `SCW_*`-secrets finns redan i org:en. Se [.github/workflows/scale-cron.yml](#) (mall i scale-cron.sh-kommentaren).
- **Scaleway Serverless Job/Cron** som kör `scale-cron.sh` — håller allt i Scaleway men kräver scw-creds i jobbet.

## Artefakter

| Fil | Roll |
|---|---|
| `Dockerfile` | combined image (multi-stage från `lux-nsp`-imagerna) → bygg + push som `server-cpu-pipeline` |
| `supervisord.conf` | fem gunicorn-program (= topologi C:s) |
| `requirements.txt` | union-deps |
| `deploy-serverless.sh` | skapar/uppdaterar serverless-containern (resurser, env, min/max-scale) |
| `scale-cron.sh` | `up`/`down` → sätter `min-scale` 1/0 |

## Runbook (med dina creds)

```bash
# 1. bygg + push combined image till lux-nsp
docker login rg.fr-par.scw.cloud -u nologin -p "$SCW_SECRET_KEY"
docker build -t rg.fr-par.scw.cloud/lux-nsp/server-cpu-pipeline:edge \
  --build-arg IMAGE_TAG=edge scaleway/
docker push rg.fr-par.scw.cloud/lux-nsp/server-cpu-pipeline:edge

# 2. deploya serverless-containern (sätter MODEL_SERVICE_URL + proxy-auth-secrets)
bash scaleway/deploy-serverless.sh

# 3. schemalägg dygns-cron (GH Actions eller Scaleway Job) → scale-cron.sh up/down
```

## Mätning

Samma `measure.py` som topologi C, mot serverless-containerns URL — jämför
cold-start + p50/p95 + €/1000 req mot A/C.

## Status

🟡 Artefakter klara (Dockerfile, supervisord.conf, requirements.txt,
deploy-serverless.sh, scale-cron.sh, scaleway.env.example, GH-workflow
scale-cron.yml). Validerade (bash/YAML). Ej byggda/deployade — kräver dina
registry-/scw-creds (kör runbooken ovan).
