# Topologi B — combined CPU-image för Scaleway Serverless Containers.
#
# Multi-stage: återanvänder de redan byggda tjänst-imagernas src/ från lux-nsp
# (ingen omkompilering av källkod), installerar union-deps en gång, kör de fem
# gunicorn-processerna via supervisor. lux exponeras på :8080.
#
# Bygg (kräver docker login mot lux-nsp för att pulla FROM-stegen):
#   docker build -t rg.fr-par.scw.cloud/lux-nsp/server-cpu-pipeline:edge \
#     --build-arg IMAGE_TAG=edge scaleway/
#
# Per-tjänst-taggar kan överstyras (default edge för alla).
ARG REGISTRY=rg.fr-par.scw.cloud
ARG NAMESPACE=lux-nsp
ARG IMAGE_TAG=edge
ARG LUX_TAG=${IMAGE_TAG}
ARG ENCODER_TAG=${IMAGE_TAG}
ARG OBSTRUCTION_TAG=${IMAGE_TAG}
ARG MERGER_TAG=${IMAGE_TAG}
ARG STATS_TAG=${IMAGE_TAG}

FROM ${REGISTRY}/${NAMESPACE}/server-lux:${LUX_TAG} AS lux
FROM ${REGISTRY}/${NAMESPACE}/server-encoder:${ENCODER_TAG} AS encoder
FROM ${REGISTRY}/${NAMESPACE}/server-obstruction:${OBSTRUCTION_TAG} AS obstruction
FROM ${REGISTRY}/${NAMESPACE}/server-merger:${MERGER_TAG} AS merger
FROM ${REGISTRY}/${NAMESPACE}/server-stats:${STATS_TAG} AS stats

FROM python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    libgl1 libglib2.0-0 libgomp1 supervisor \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Källkod från respektive tjänst-image. lux/encoder lägger src under /app/src;
# obstruction/merger/stats under /src (se deras Dockerfiles).
COPY --from=lux         /app/src  /app/lux/src
COPY --from=encoder     /app/src  /app/encoder/src
COPY --from=obstruction /src      /app/obstruction/src
COPY --from=merger      /src      /app/merger/src
COPY --from=stats       /src      /app/stats/src

COPY supervisord.conf /app/supervisord.conf

# Non-secret runtime-env. MODEL_SERVICE_URL + MODAL_KEY/MODAL_SECRET sätts vid
# deploy (deploy-serverless.sh) så secrets aldrig bakas in i imagen.
ENV DEPLOYMENT_MODE=production \
    AUTH_TYPE=none \
    ENCODER_SERVICE_URL=http://localhost:8082 \
    OBSTRUCTION_SERVICE_URL=http://localhost:8081 \
    MERGER_SERVICE_URL=http://localhost:8084 \
    STATS_SERVICE_URL=http://localhost:8085 \
    PYTHONUNBUFFERED=1 \
    CUDA_VISIBLE_DEVICES=-1 \
    PORT=8080

EXPOSE 8080
CMD ["supervisord", "-n", "-c", "/app/supervisord.conf"]
