"""Topologi C — hela CPU-pipelinen som EN Modal-app (combined container).

server-lux + encoder/obstruction/merger/stats körs i ETT image, startade av
supervisor på interna portar; lux pratar localhost (1 cold start, inga
nätverkshopp). GPU-inferens via den fristående model_gpu-deployen
(MODEL_SERVICE_URL → *.modal.run, proxy-auth bifogas av lux). Mål: mäta perf +
kostnad mot topologi A/B.

Deploy (från infra.lux/modal/cpu_pipeline/):
    modal deploy -m app

Kräver en Modal Secret 'upskiller-modal-proxy' med MODAL_KEY + MODAL_SECRET
(proxy-auth mot GPU-appen):
    modal secret create upskiller-modal-proxy MODAL_KEY=wk-... MODAL_SECRET=ws-...
"""
import subprocess
from pathlib import Path

import modal

APP_NAME = "upskiller-cpu-pipeline"
PROXY_SECRET_NAME = "upskiller-modal-proxy"
# Den fristående GPU-deployens endpoint (se ../model_gpu/model.env).
GPU_ENDPOINT = "https://stasya00--upskiller-model-inferenceservice-web.modal.run"

LUX_PORT = 8080
CPU = 4.0
MEMORY_MB = 4096
MIN_CONTAINERS = 0          # scale-to-zero (mät cold start)
SCALEDOWN_WINDOW = 60       # snabb scale-to-zero, minimal idle-kostnad
REQUEST_TIMEOUT = 900
STARTUP_TIMEOUT = 180       # 5 gunicorn-processer ska hinna boota

# Non-sensitive env. lux läser SERVICE_URL:erna; localhost = samma container.
RUNTIME_ENV = {
    "DEPLOYMENT_MODE": "production",
    "AUTH_TYPE": "none",                          # öppet för mätning; sätt token/auth0 i prod
    "ENCODER_SERVICE_URL": "http://localhost:8082",
    "OBSTRUCTION_SERVICE_URL": "http://localhost:8081",
    "MERGER_SERVICE_URL": "http://localhost:8084",
    "STATS_SERVICE_URL": "http://localhost:8085",
    "MODEL_SERVICE_URL": GPU_ENDPOINT,            # *.modal.run → lux bifogar proxy-auth
    "PYTHONUNBUFFERED": "1",
    "CUDA_VISIBLE_DEVICES": "-1",
}

# server_* ligger som syskon till infra.lux under upskiller/. ROOT används bara av
# add_local_dir vid BUILD (lokalt). I containern är __file__=/root/app.py (grunt),
# och modulen re-importeras vid boot — så fallbacken måste vara krasch-säker (annars
# IndexError vid runtime). add_local_dir-argumenten är no-ops i containern.
_HERE = Path(__file__).resolve()
ROOT = _HERE.parents[3] if len(_HERE.parents) >= 4 else _HERE.parent

app = modal.App(APP_NAME)

image = (
    modal.Image.debian_slim(python_version="3.11")
    .apt_install("libgl1", "libglib2.0-0", "libgomp1", "supervisor")
    .pip_install_from_requirements("requirements.txt")
    .env(RUNTIME_ENV)
    .add_local_file("supervisord.conf", "/app/supervisord.conf", copy=True)
    .add_local_dir((ROOT / "server_lux/src").as_posix(), "/app/lux/src", copy=True)
    .add_local_dir((ROOT / "server_encoder/src").as_posix(), "/app/encoder/src", copy=True)
    .add_local_dir((ROOT / "server_obstruction/src").as_posix(), "/app/obstruction/src", copy=True)
    .add_local_dir((ROOT / "server_merger/src").as_posix(), "/app/merger/src", copy=True)
    .add_local_dir((ROOT / "server_stats/src").as_posix(), "/app/stats/src", copy=True)
)


@app.function(
    image=image,
    secrets=[modal.Secret.from_name(PROXY_SECRET_NAME)],
    cpu=CPU,
    memory=MEMORY_MB,
    min_containers=MIN_CONTAINERS,
    scaledown_window=SCALEDOWN_WINDOW,
    timeout=REQUEST_TIMEOUT,
)
@modal.web_server(port=LUX_PORT, startup_timeout=STARTUP_TIMEOUT)
def serve() -> None:
    # supervisord -n kör i förgrunden som barnprocess; Popen returnerar direkt så
    # web_server kan börja polla lux-porten medan de fem gunicorn-processerna bootar.
    subprocess.Popen(["supervisord", "-n", "-c", "/app/supervisord.conf"])
