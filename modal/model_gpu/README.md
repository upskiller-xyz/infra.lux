# GPU-inferens (server-model på Modal) — fristående deploy

Den **enda** inferens-backenden i stacken. Deployas oberoende av CPU-topologierna;
A (VM), B (serverless) och C (allt-på-Modal) konsumerar den bara via env.

> **Källkoden bor i `server_model`** (`server_model/modal_app/`), eftersom Modal-appen
> är kopplad till `server_model/src` och bakar in modeller i imagen vid build.
> infra.lux **äger inte koden** — det pinnar versionen, dokumenterar kontraktet och
> kör deployen. Ändra aldrig modall-appens beteende här; gör det i `server_model`.

## Kontrakt (det A/B/C beror på)

| | |
|---|---|
| Modal-app | `upskiller-model` |
| Endpoint | `https://<workspace>--upskiller-model-inferenceservice-web.modal.run` |
| Routes | `POST /run` (multipart: file, model, valfri cond_vec), `GET /spec?model=`, `GET /status` |
| Auth | Modal proxy-auth: headers `Modal-Key` / `Modal-Secret` |
| GPU | L4, scale-to-zero (`min_containers=0`, `scaledown_window=300s`) |

Konsumenter sätter bara:

```
MODEL_SERVICE_URL=https://<workspace>--upskiller-model-inferenceservice-web.modal.run
MODAL_KEY=wk-...
MODAL_SECRET=ws-...
```

server-lux auto-detekterar `*.modal.run` och bifogar proxy-auth automatiskt.

## Deploya

```bash
# Pinnad version + skalning ligger i model.env.
bash deploy.sh            # checkar ut server_model på MODEL_REF och kör `modal deploy`
```

Se [model.env](model.env) för pinnad version och skalningsval.

## Skalning

Standard är scale-to-zero (billigast, ~8.9s cold start tack vare CPU-memory-snapshot).
Vill du undvika cold start under dagen: höj `MIN_CONTAINERS` i `server_model/modal_app/config.py`
(inte här) — eller, om vi vill styra det från infra utan att röra koden, lyft värdet
till en env och läs det i config (separat uppgift, se rollout-steg).
