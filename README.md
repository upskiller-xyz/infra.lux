# infra.lux

Deployment och drift för Upskiller-stacken. **Detta repo bygger ingen källkod** —
det refererar färdiga, taggade bilder och orkestrerar var de körs.

> Status: RFC / konventioner spikade. Implementationen rullas ut stegvis (se
> [Rollout](#rollout)). Detta dokument är källan till sanning för tagg-schema,
> release-manifest och kontraktet mot GPU-inferensen.

## Arkitektur

`server-lux` är gateway/orkestrator och anropar mikrotjänsterna:

```
                       ┌───────────────────────────────────────┐
   klient ─▶ nginx ─▶  │ server-lux (CPU)                       │
                       │   ├─▶ server-encoder    (CPU)          │
                       │   ├─▶ server-merger      (CPU)         │
                       │   ├─▶ server-obstruction (CPU)         │
                       │   └─▶ server-stats       (CPU)         │
                       └───────────────┬───────────────────────┘
                                       │  MODEL_SERVICE_URL (+ proxy-auth)
                                       ▼
                            server-model (GPU) på Modal   ← egen deploy, delas
```

**Princip:** GPU-inferensen är en *fristående deploybar enhet* (se
[modal/model_gpu](modal/model_gpu/)). CPU-topologierna nedan är konsumenter som
bara pekar `MODEL_SERVICE_URL` på dess endpoint. Att byta CPU-topologi rör aldrig
GPU:n; att uppdatera modellen rör aldrig CPU-delen.

## Deployment-topologier

| | CPU körs på | GPU körs på | Autoskala | Använder |
|---|---|---|---|---|
| **A. VM** | Scaleway Instance (compose, pull) | Modal | nej | [compose/](compose/) |
| **B. Serverless** | Scaleway Serverless Containers | Modal | ja (min/max + dygns-cron) | [scaleway/](scaleway/) |
| **C. Allt på Modal** | Modal (en CPU-pipeline-app) | Modal | ja (scale-to-zero) | [modal/cpu_pipeline/](modal/cpu_pipeline/) |

Alla tre konsumerar samma GPU-deploy via `MODEL_SERVICE_URL` + `MODAL_KEY`/`MODAL_SECRET`.

## Bild- och taggschema

Bilder byggs av **varje tjänst-repos** CI (på tag/merge) eller `workflow_dispatch`,
aldrig på prod-VM:en. Ett delat skript, [scripts/release.sh](scripts/release.sh),
räknar ut taggarna från git-tillståndet och kör identiskt i CI och lokalt. Varje
build pushar flera taggar mot **samma digest**.

Registry: `rg.fr-par.scw.cloud/<namespace>/<image>`

| Trigger | Immutabel tagg | Rörlig tagg |
|---|---|---|
| Git-tag `v1.2.0` (release) | `<image>:1.2.0` | `<image>:latest` |
| Merge → master | `<image>:1.2.0-5-g<sha>` (`git describe`) | `<image>:edge` |
| Anrop / `workflow_dispatch` | `<image>:<branch>-<sha>` (+ valfri `--postfix`) | — (rör aldrig latest/edge) |

- `latest` ⇒ senaste **release**. `edge` ⇒ senaste **master**. Symmetriskt.
- `git describe` (`1.2.0-5-g<sha>`) = "5 commits efter v1.2.0" — immutabel, spårbar, sorterbar.
- Manuella builds rör aldrig `latest`/`edge`.
- Alla bilder byggs `linux/amd64` (buildx) och får OCI-labels (`org.opencontainers.image.revision=<sha>`).

**I prod pinnas exakt semver/sha** — aldrig `latest`/`edge`. De är för dev/bekvämlighet.

## Release-manifest

Vad som körs var styrs av **två** manifest, inte av källkod:

- [images.env](images.env) — `REGISTRY` + `NAMESPACE` + CPU-tjänsternas taggar (`ENCODER_TAG=1.2.0`, …).
  **Enda källan** för `REGISTRY`/`NAMESPACE`: läses av både CI (release-actionen `source`:ar den)
  och `deploy-vm.sh` på VM:en. Byt namespace eller registry → en edit här, inga GitHub-variabler.
  (Zonen är inte en egen variabel — den ingår i `REGISTRY`-hosten, t.ex. `fr-par` i
  `rg.fr-par.scw.cloud`; byter du region byter du `REGISTRY`-värdet.)
- [modal/model_gpu/model.env](modal/model_gpu/model.env) — GPU:ns egen livscykel (`MODEL_REF`, GPU-typ, skalning). Konsumeras av GPU-deployen.

Release = ändra en tagg i manifestet, pulla/redeploy. Rollback = sätt tillbaka taggen.

## Rollout

1. ✅ Initiera infra.lux: konventioner (detta dokument) + skelett.
2. ✅ `scripts/release.sh` + composite action — utrullad i alla sex repon (SHA-pinnad), bevisad på `server_encoder` (image i `lux-nsp`).
3. ✅ GPU-deploy som fristående enhet — kontrakt + wrapper i [modal/model_gpu](modal/model_gpu/) (källkod bor i `server_model`). **Verifierad skarpt 2026-06-13**: `deploy.sh` re-deployar (cachad image), endpoint uppe, proxy-auth påtvingad (401/200), `/status` OK.
4. ✅ VM-deploy → pull (topologi A) i [compose/](compose/), inkl. cloudflare/nginx/fail2ban. Migrerat från `server_lux/deployment/`.
5. ⬜ Modal CPU-pipeline (topologi C) + mätscript → perf/kostnads-test (p50/p95, cold-start, €/1000 req).
6. ⬜ Scaleway serverless (topologi B) + dygns-cron för `min-scale`.

## Migration ut ur server_lux

Deployment-tillgångarna flyttas FRÅN `server_lux/deployment/` HIT. När infra.lux är
verifierat ska följande tas bort ur server_lux (de duplicerar nu infra.lux):

- `deployment/services/` — de inklonade mikrotjänsterna (ersatta av registry-pull)
- `deployment/docker-compose.scaleway.yml`, `nginx-scaleway.conf`, `deploy-scaleway.sh` → migrerat till [compose/](compose/)
- `deployment/setup-cloudflare.sh`, `setup-vm.sh` → [compose/](compose/)
- `deployment/certs/`, `deployment/fail2ban/` → [compose/](compose/)
- `deployment/.env.scaleway.example` → [envs/vm.env.example](envs/vm.env.example)

Legacy-varianter (full-stack-/docker-compose med model som container, GCP Cloud Run-
skript) migreras inte 1:1 — de ersätts av topologierna A/B/C. Behåll i git-historiken.
