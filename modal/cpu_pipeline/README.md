# Topologi C — CPU-pipelinen på Modal

CPU-delen (server-lux + encoder/merger/obstruction/stats) körs på Modal i stället
för på en VM/serverless; GPU-inferensen ligger kvar på den fristående
[model_gpu](../model_gpu/)-deployen. Syftet är att **mäta perf + kostnad** mot
topologi A/B.

## Hur CPU-delen ser ut idag

server-lux:s `Orchestrator` (`src/server/services/orchestration/orchestrator.py`)
kör en **sekvens av remote HTTP-tjänster** per endpoint — varje steg är ett
HTTP-anrop till en separat Flask-tjänst (encoder, obstruction, merger, stats,
model_spec) via `*_SERVICE_URL`. Tjänsterna är alltså löst kopplade över HTTP.

## Designgaffel (avgör cold-start + kostnad)

| | Upplägg | Cold starts | Hopp | Kodändring | Notering |
|---|---|---|---|---|---|
| **1. N separata Modal-endpoints** | varje tjänst = egen Modal-web-app | **N** per request | N nätverkshopp | ingen | Sämst för latens — undviks |
| **2. Combined container (rek. för testet)** | EN Modal-app: ett image som kör lux + 4 tjänster (supervisor), lux anropar dem på `localhost` | **1** (men tung boot: 5 gunicorn) | localhost | ingen | Återanvänder befintliga images/kod oförändrat. Enklast att mäta mot. |
| **3. In-process bibliotek** | tjänsternas compute refaktoreras till importbara libs i en Modal-funktion | 1 (snabb) | in-process | **stor** (paketera om 4 repon) | Lägst latens, men kräver omskrivning — optimering *efter* mätning |

`MODEL_SERVICE_URL` → den fristående GPU-Modal-appen i alla upplägg.

## Rekommendation

Bygg **upplägg 2** som testfordon: en Modal-app med ett combined image (de fyra
CPU-tjänsternas + lux kod, startade av supervisor på interna portar, lux pratar
`localhost`), exponerad via lux ASGI/WSGI som en `@modal.asgi_app`. Det
återanvänder befintlig kod oförändrat och ger en rättvis mätpunkt. Om cold-start
(5 processer som bootar) visar sig vara flaskhalsen → överväg upplägg 3.

## Mätplan (samma tre mått för A/B/C)

- **Latens** p50/p95 (varm + cold-start separat)
- **Cold-start-tid** (tid till första 200 efter scale-to-zero)
- **€ / 1000 requests** (Modal CPU-tid + ev. GPU-anrop)

Mätskript: `measure.py` (kör N requests mot endpointen, loggar latens-percentiler
och uppskattad kostnad). Byggs tillsammans med appen.

## Status

⬜ Ej byggt. Väntar på bekräftelse av upplägg (2 rekommenderas) innan app.py +
measure.py skrivs.
