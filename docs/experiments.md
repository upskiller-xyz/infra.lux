# Experiment & mätningar — deployment-topologier

Perf/kostnad för Upskiller-stacken. GPU-inferensen är en **delad backend**; de fyra
topologierna skiljer sig i **var CPU-pipelinen och GPU:n körs**. Datum: 2026-06-13.

## Topologier (alternativ)

| | CPU-pipeline | GPU-inferens | Cold start? | Status |
|---|---|---|---|---|
| **A** | VM | **samma VM** | **nej** (allt always-on) | delvis mätt |
| **B** | VM | Modal | bara GPU | ✅ mätt |
| **C** | Modal (combined container) | Modal | CPU **+** GPU | ✅ mätt |
| **D** | Scaleway serverless | Modal | CPU + GPU | ⬜ ej implementerat |

> **A = allt på EN VM** (lux + encoder/merger/obstruction/stats **+ modellen**, samma
> maskin). **B är samma VM** men modellen är flyttad till Modal (`MODEL_SERVICE_URL`
> → `*.modal.run`). Skillnaden A↔B är alltså bara var inferensen körs.

> **Cold start gäller bara Modal-/serverless-delar.** En VM är always-on och
> cold-startar inte — det som ser ut som "VM-cold" (t.ex. tidigare 36.61s) är
> **första-request-warmup + klient-brus**, inte en äkta cold start. Så:
> - **A**: ingen cold start någonstans.
> - **B**: bara GPU:n (Modal scale-to-zero) cold-startar.
> - **C/D**: både CPU-containern och GPU:n cold-startar.

## Pipeline-stegen (samma kod i alla topologier)

```
endpoint-entry → [lux-gap: parse body/mesh] → /spec → encoder×3 → /encode → /run (GPU) → /merge
```
Obstruction skippas när horizon/zenith redan är precalc:ade. `/spec` cachas i lux
(per process) → träffar GPU bara vid cache-miss (kall container / första requesten).

## Mått-disciplin

Mät **server-internt** ("Processing endpoint" → sista merger-svaret). **Klient-totalen
är opålitlig** — samma server-trace rapporterades som **6.2 / 9.66 / 26.2s** pga
mesh-upload (474k trianglar) + nätverk + Cloudflare. Modal-GPU cold-start varierar
**3–10s** (snapshot-restore beror på om workern har image-lagren cachade).

---

## GPU-inferens (delad backend)

| Backend | `/run` varm | `/run` kall | Not |
|---|---|---|---|
| **Modal L4** (scale-to-zero, snapshot) | ~1.3–2.0s (i pipeline) | ~5–21s (snapshot-restore + CUDA-init, varierar) | `/warm`-prewarm finns; `/status` kall ~6.7s |
| **Modellen på VM:en** (A, always-on, lokal) | ~8.9s | — (ingen cold) | mycket långsammare än Modal-GPU → trol. **CPU-inferens** på VM:en (ingen GPU), **bekräfta** |

Cold-GPU-breakdown (Modal, via `/spec`-anrop): kö 0.67s + snapshot-restore 3.38s +
exec 0.85s ≈ 4.9s (lätt restore). Tyngre cold: exec själv ~16s (CUDA/ORT-init på
första inferensen, eftersom GPU-snapshot är av).

---

## Per-steg — VARM (server-internt, 1 fönster, spec cachad)

| Steg | A (allt på VM) | B (VM CPU + Modal GPU) | C (allt på Modal) |
|---|---|---|---|
| lux-gap (body/mesh-parse) | ~2.8s | **2.80s** | ⬜ |
| `/spec` | cache hit 0 | cache hit 0 | cache hit 0 |
| encoder ×3 | ~0.01s | 0.01s | 0.01s |
| `/encode` | ~0.8s | 0.78s | ~0.8s |
| `/run` (GPU) | **~8.9s** (VM) | **1.30s** (Modal) | ~1.3s |
| `/merge` | ~0.2s | 0.16s | 0.18s |
| **Server-internt** | **~12.7s** (est.) | **~5.1s** | ⬜ |

B snabbast varmt. A:s VM-inferens (~8.9s) gör totalen hög trots always-on.

## Per-steg — KALL (bara där cold start finns)

| Steg | B (Modal-GPU kall) | C (Modal CPU+GPU kall) |
|---|---|---|
| CPU-container boot | — (VM) | **~8.4s** (5 gunicorns) |
| lux-gap | 3.07s | ⬜ |
| `/spec` (GPU) | 2.97s (kall GPU, prewarm-försprång) | 5.21–9.5s (kall GPU, blockar) |
| `/encode` | 0.82s | 0.97s |
| `/run` (GPU) | 2.0s (varm efter /spec) | 2.07s |
| `/merge` | 0.18s | 0.18s |
| **Server-internt** | **~9.1s** | **~16.6s** |

A: ingen kall kolumn (always-on). D: ⬜.

---

## Varianter

### Prewarm — `/warm`-ping vid request-entry (på/av)
Lux fyrar fire-and-forget `/warm` mot Modal-GPU så fort en inferens-request kommer
(`ModelPrewarmer`, gate:ad på Modal-backend → no-op för VM-GPU).

| | Av | På |
|---|---|---|
| Kall GPU betalas på | första GPU-anropet, serialiserat (`/spec` om ej cachat, annars `/run` = **6.93s**) | GPU värms parallellt från t=0 |
| Vinst | — | ~"försprånget" (entry→/spec ≈ 3s) göms |
| Begränsning | — | `/spec` träffar GPU synkront → resten betalas där ändå |
| Cold + spec-cachad + prewarm `/run` | 6.93s (baslinje) | ⬜ mät |

### Flytta `/spec`-resolution till CPU (på/av)
| | Av (nu) | På |
|---|---|---|
| `/spec`-källa | GPU-container | publika bucketen (lux/CPU) |
| Kall container (cache tom) | `/spec` **blockar** på GPU-cold | `/spec` snabb, GPU:s enda synkrona träff = `/run` |
| Prewarm-effekt | begränsad | **full** — cold-starten kan gömmas bakom encode |

⏸️ **Uppskjuten** (en modell + spec cachad), men **förutsättning** för full prewarm-vinst i cold-fallet.

---

## Design — mesh som pass-through (implementerad)

Problemet: meshen låg **inline** i JSON-bodyn, så lux:s `orjson.loads(hela body)`
materialiserade den fast lux aldrig använder den. Lösning = **skicka meshen som eget
fält** så lux aldrig rör den.

**API (`/v1/run`) → multipart (original-JSON-anropet funkar oförändrat):**
- `params` (application/json): `model_type`, `parameters` (room_polygon, windows, höjder…) — **litet**, parsas alltid.
- `mesh` (fil): meshen som **JSON-array** *eller* **binärt `.npy`** (valfritt gzippat) — **stort**, lux parsar det **aldrig**.

**Flöde (lux):**
- `orjson.loads(params)` (~ms). `mesh`-filen läses som rå bytes (`request.files['mesh']`).
- **Binär mesh** (`.npy`/gzip, identifieras via magic-bytes `\x93NUMPY` / `\x1f\x8b`): hålls som **rå bytes** och forwardas oparsat till obstruction.
- **JSON-mesh**: parsas bara om obstruction körs (annars droppas den).
- **Obstruction skippas** (precalc:ad horizon+zenith) → mesh-bytes rörs **aldrig**.

**Obstruction — ny binär endpoint `/obstruction_parallel_bin`** (JSON-tvillingen kvar):
- Multipart: `params` (JSON, fönsterfält) + `mesh`-fil (`.npy`, valfritt gzippat).
- `NpyMeshDecoder` (Strategy): gunzip vid behov → `np.load` → `(N,3)`-array → vertis-lista.
  Samma validerings-/service-/svarslogik som JSON-vägen (mappas via `BinaryEndpointLogicalMap`).
- Parsen blir `np.load` (~ms) i stället för flersekunders JSON-parse.

**Vinst:** lux:s mesh-parse försvinner i *varje* request; re-serialiseringen
till obstruction försvinner; obstruction-parsen går från JSON (~s) till `np.load` (~ms).
Binärt = ~15x mindre på tråden (86 MB → 5,7 MB); gzip ovanpå gav här **5,6x till**
(5,70 → 1,02 MB — geometri-koordinater är spatialt sammanhängande, komprimerar bra).

**Mätning — uppmätt i prod (988.json, 474 765 vertiser / 158k trianglar, VM-IP direkt):**

| Variant (samma mesh, `/run`)        | Uppladdning (MB) | `extract_params` (lux) | obstruction-parse        |
|-------------------------------------|------------------|------------------------|--------------------------|
| JSON inline (baslinje)              | ~86              | ~5664 ms               | JSON-parse ~s            |
| **.npy** multipart                  | 5,70             | 3522 ms                | `decode_mesh` **103 ms** |
| **.npy + gzip** multipart           | **1,02**         | **1704 ms**            | `decode_mesh` 103 ms     |

`extract_params` är **upload-bundet** (gzip ~halverade den; obstruction tar emot samma
mesh + `np.load` på ~130 ms över interna nätet). Golvet = klientens upstream-bandbredd.
Rekommendation: **`USE_GZIP=True` som default** för stora meshar.

**Obstruction-steget, uppdelat (`/obstruction_parallel_bin`, samma mesh):**

| Steg                  | Tid     | Vad |
|-----------------------|---------|-----|
| `decode_mesh`         | 103 ms  | `np.load` (gzip-detektering + dekomprimering) |
| `mesh_build`          | 742 ms  | `Mesh.from_vertices` → Point3D/Triangle-objekt (O(N) Python) |
| `compute_directions`  | 5314 ms | 64-riktnings ray cast — **dominerar** |

> ⚠️ `Mesh.from_vertices` bygger Python-`Point3D`/`Triangle`-objekt i en loop (O(N)) →
> 742 ms. Binärt tog bort *JSON-decode*-kostnaden, inte objektbygget. Nästa (separat) spår:
> **vektorisera geometrin** (numpy `(N,3,3)` istf objekt) → dödar `mesh_build` + snabbar
> ray-castet; + **spatial index (BVH/grid)** för `compute_directions`.

## Obstruction-optimering (egen gren `fix/vectorize-obstruction`)

### Fas 1 — packa `tri_arrays` en gång (gjort ✅)
`GapObstructionOrchestrator` anropade `RayTriangleIntersector.prepare_arrays(mesh.triangles)`
**per riktning** — fast meshen är identisk för alla 64. En Python-loop över 158k trianglar,
64 gånger.

- **Fix:** packa `tri_arrays` en gång i `ObstructionService` efter filtrering, skicka den
  (read-only) till alla riktningar. Optional `tri_arrays`-param genom
  orchestrator/calculator/async-calculator; faller tillbaka till mesh-packning för
  unit-test/legacy-anropare.
- **Mätt på VM:** `compute_directions` **5314 → 1759 ms** (−3,5 s). `prepare_arrays`: 64× → 1×.
- Identiska resultat (np.allclose), regressionstest `prepare_arrays == 1`.

### Fas 2 — numpy hela vägen (vad vi upptäckte)
**Upptäckt:** mesh-datan round-trippas **objekt ↔ numpy 5–6 gånger** per request:

```
decode → list
 → Mesh.from_vertices          # list → Point3D/Triangle-objekt   (713 ms)
 → coarse_filter._vectorize    # objekt → (N,3,3) array (loop)
 → coarse_filter._build_list   # mask → Triangle-tuple (loop)
 → height_filter._vectorize    # objekt → array igen (loop)
 → height_filter._build_list   # mask → Triangle-tuple igen (loop)
 → prepare_arrays              # Triangle-tuple → array (loop)  ← Fas 1 gjorde 1×
```

Filtren räknar redan sina masker på numpy (`_filter_by_height`, normal-dot) — men packar
**upp till objekt och ner igen** varje gång. All compute nedströms
(`VectorizedElevationAngleCollector`, Moller-Trumbore `batch_hits_any`) tar redan
`TriangleArrays` (numpy). Objekten behövs i praktiken bara av single-direction-vägen
(`/horizon`, `/zenith`, `/obstruction` via `IntersectionCalculator`).

**Plan (numpy som sanningskälla, lat `triangles` för legacy):**
1. **`Mesh` numpy-backad:** håll `(M,3,3)`-array som källa; `from_vertices` lagrar
   `np.asarray(...).reshape(-1,3,3)` (**6 ms** istf 713). `triangles`-property byggs
   **lat** (bara om en legacy-väg rör den). Ny `from_array` + `vertices_array`.
2. **Filter array-native:** lägg `mask(vertices_array, window) -> bool[N]` i
   `TriangleFilter`; behåll `call(triangles, …)` (legacy) som anropar `mask`.
   `MeshFilterService` jobbar array→array: `Mesh.from_array(arr[mask])` — ingen
   objekt-ompackning.
3. **`prepare_arrays` från array:** `RayTriangleIntersector.from_array(vertices_array)`
   (slice, ~6 ms). `ObstructionService` packar därifrån.

**Effekt (uppmätt, gjort ✅):** `Mesh` numpy-backad med lat `triangles`; filtren har
`mask(vertices_array, window)` (array-native) och `MeshFilterService` jobbar array→array;
`RayTriangleIntersector.from_array` packar via slice.
- **`mesh_build`: 798 → 115 ms** (7×). Filtrens vectorize/rebuild-loopar borta;
  prepare-loop → slice. Identiska resultat (np.allclose, 64 riktningar). 227 tester
  gröna (samma 4 pre-existing fel). Single-direction-vägen oförändrad (lat `.triangles`).

### Fas 2b — numpy genom decoder + validatorer (gjort ✅)
**Oväntat fynd vid mätning:** den verkliga residualen var **inte** `mesh_build` utan
**valideringen**: `RequestValidator.call` på en 474k-vertex *lista* tog **1479 ms**, och
boven var `WindowNotOnMeshValidationStep` (**1634 ms** isolerat) — den byggde en `Mesh`
+ `find_triangle_containing_point` som **loopar 474k trianglar till en array** (point-on-
mesh-checken var redan vektoriserad, men matades via objekt).

**Fix:**
1. `GeometryValidator._index_on_mesh(point, vertices_array, tol)` — array-native;
   `validate_point_not_on_mesh_array` använder `mesh.vertices_array` (inga objekt).
2. `NpyMeshDecoder` returnerar `(N,3)`-arrayen (ingen `.tolist()`); `MeshFormat`/
   `VertexFormatValidationStep` + `ObstructionRequest._parse_mesh` + `Mesh.from_array`
   accepterar `np.ndarray`. Binärvägen är nu numpy **hela vägen** (decode → validering
   → mesh → compute). JSON-vägen (lista) oförändrad.

**Mätt:** `RequestValidator.call` **1479 → 51 ms** på arrayen (WindowNotOnMesh 1634→fast).
Identiska resultat (np.allclose, 64 riktningar). 227 tester gröna (samma 4 pre-existing).

### Obstruction — totalt (uppmätt på VM, varm)
| Steg | Start | Fas 1 | Fas 2 | Fas 2b |
|------|-------|-------|-------|--------|
| `mesh_build` | 742 ms | 742 | **122** | (numpy) |
| `compute_directions` | 5314 ms | 1759 | **1082** | 1082 |
| validering (otidsatt) | ~1,5 s | ~1,5 s | ~1,5 s | **~0,05 s** |
| **obstruction wall** | **~7,7 s** | ~4,1 s | ~3,0 s | **~1,3 s** |

**Kvar (eget spår, avtagande avkastning):** `compute_directions` ~1,1 s = äkta
vektoriserat ray-cast × 64 → **spatial index (BVH/grid)** eller LOD-decimering.

## Per-steg — VARM e2e `/run` (988.json, binär+gzip, VM-IP direkt)
| Del | Tid (varm) |
|-----|-----------|
| lux `extract_params` (gzip 1,02 MB) | ~0,16 s |
| encoder: reference / direction / external | ~0,01 s |
| **obstruction** (`/obstruction_parallel_bin`) | ~1,3–3,0 s* |
| **model (Modal GPU, varm)** | ~3,5 s |
| merger | ~0,17 s |
| **e2e totalt** | **~6,9 s** (kall: ~18 s, dominerad av Modal-kallstart) |

\* obstruction efter Fas 2b ~1,3 s lokalt; VM-siffran mäts efter deploy. De två stora
posterna är nu **obstruction-ray-cast** och **GPU-inferensen** — ungefär lika stora.

**Modal-kallstart:** prewarm-pingen hjälper bara om det finns CPU-arbete att överlappa
med (obstruction räcker när den körs); mot en helt kall ~15 s container hinner den inte.
Eget spår: minska kallstart (snapshot / min-scale-fönster).

## Nyckelfynd

1. **lux-gap = JSON-parsning av meshen — BEKRÄFTAT.** `[timing] extract_params: 4011ms`
   (~48% av server-tiden). `request.get_json()` parsar en ~86 MB mesh (474k trianglar).
   - **Fix 1 (gjort): orjson** i `extract_params` → ~**1.7x** (4.0s → ~2.4s på VM). Gratis, låg risk.
   - **Fix 2 (den stora häven):** **lux *använder* aldrig meshen — den bara
     vidarebefordrar den till obstruction** (enda konsumenten). Så lux-parsningen är
     slöseri i ALLA fall: obstruction skippas → ren waste; obstruction körs → lux
     parsar + **re-serialiserar** + obstruction **parsar om** (meshen hanteras 3×).
     Fix: **gör lux till ren genomströmning** — parsa aldrig meshen, skicka den rå
     vidare. Meshen skickas som separat multipart-fält (JSON eller binärt `.npy`/gzip).
     **Implementerad** (se "Design"). ✅

5. **Obstruction = 8.28s när det körs** (64-riktnings ray casting över 474k-triangel-
   meshen) — tyngsta enskilda steget. Meshen skickas dit av lux och parsas om där.
   Binär `.npy`-endpoint (`/obstruction_parallel_bin`) gör om-parsen till `np.load`
   (~ms i st.f. ~s). Kvarvarande spår: BVH/spatial-index, LOD-mesh, vektorisera
   `Mesh.from_vertices`. Instrumentera obstruction med `[timing]` för parse-vs-compute-split.
2. **Klient-totalen är opålitlig** — mät server-internt.
3. **Prewarm + /spec-flytt hör ihop** — prewarm ensam ger lite tills `/spec` slutar
   blocka GPU synkront.
4. **VM = ingen cold start, men 24/7-kostnad.** Modal/serverless = scale-to-zero
   (billigt vid låg last) men cold start.

## Att göra

- [x] lux-gap = mesh JSON-parse, bekräftat (`extract_params` 4011ms). orjson infört (~1.7x → ~2.4s)
- [x] **(stor vinst)** mesh pass-through (multipart) — lux parsar aldrig meshen. Implementerad: JSON + binär `.npy`/gzip, ny `/obstruction_parallel_bin`
- [x] **Mät** pass-through-varianterna — uppmätt: `.npy` 5,70 MB / extract_params 3522 ms; +gzip 1,02 MB / 1704 ms; obstruction `decode_mesh` 103 ms (se tabell i "Design"). `USE_GZIP=True` rekommenderas.
- [x] Instrumentera obstruction med `[timing]` → split: decode 103 ms / mesh_build 742 ms / compute_directions 5314 ms
- [x] **vektorisera obstruction-geometrin** (numpy `(N,3,3)`) — Fas 1 (pack 1×: compute 5314→1759), Fas 2 (numpy-mesh: mesh_build 742→122, compute→1082), Fas 2b (numpy genom validatorer: validering 1479→51 ms). Obstruction wall ~7,7 → ~1,3 s.
- [ ] **(nästa, eget spår)** spatial index (BVH/grid) för `compute_directions` (~1,1 s ray-cast); minska Modal-kallstart (snapshot/min-scale)
- [ ] **A**: mät full pipeline (allt på VM, modellen lokal på samma maskin) — saknas
- [ ] **B**: cold + spec-cachad + prewarm `/run` vs 6.93s-baslinjen
- [ ] **C**: full-pipeline `/run` (inte bara gateway)
- [ ] **D**: implementera (scaleway serverless) + mät
- [ ] `/spec`-flytt (förutsättning för prewarm-vinst i cold)
- [ ] €/1000 req per topologi (kostnadskolumn)
