"""Mät en topologi-endpoint (C, men funkar för A/B med) — latens p50/p95,
cold-start och en grov €/1000-requests-uppskattning.

Samma tre mått för alla topologier så de kan jämföras rättvist.

Exempel:
    # health/warm-latens mot topologi C:
    python measure.py --url https://stasya00--upskiller-cpu-pipeline-serve.modal.run --n 30

    # full pipeline-request (multipart) — mät den riktiga vägen:
    python measure.py --url <...> --path /v1/run --file ../../assets/sample1.png \
        --model df_default_2.0.2

    # mät cold-start: vänta in scale-to-zero (scaledown 300s) först:
    python measure.py --url <...> --cold-wait 330

Kostnadsuppskattningen är just en uppskattning (single-stream wall-time × resurs-
pris). Justera --cpu/--mem/--price-* efter din Modal-plan. Den fångar inte
concurrency-vinster och GPU-anropets kostnad räknas separat på model_gpu-appen.
"""
import argparse
import statistics
import time
from typing import Optional

import requests


def percentile(values: list[float], p: float) -> float:
    if not values:
        return float("nan")
    s = sorted(values)
    k = (len(s) - 1) * p
    lo = int(k)
    hi = min(lo + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (k - lo)


def one_request(url: str, path: str, file: Optional[str], model: Optional[str],
                timeout: float) -> tuple[int, float]:
    t0 = time.perf_counter()
    if file:
        with open(file, "rb") as fh:
            resp = requests.post(
                f"{url}{path}",
                files={"file": (file.split("/")[-1], fh, "image/png")},
                data={"model": model} if model else {},
                timeout=timeout,
            )
    else:
        resp = requests.get(f"{url}{path}", timeout=timeout)
    return resp.status_code, time.perf_counter() - t0


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True, help="Endpoint base, t.ex. https://...serve.modal.run")
    ap.add_argument("--path", default="/", help="Path att mäta (default health '/')")
    ap.add_argument("--n", type=int, default=30, help="Antal warm-requests")
    ap.add_argument("--file", help="Bildfil för multipart pipeline-request")
    ap.add_argument("--model", help="model-fältet för pipeline-request")
    ap.add_argument("--timeout", type=float, default=180.0)
    ap.add_argument("--cold-wait", type=float, default=0.0,
                    help="Vänta N sekunder före första requesten (mät scale-to-zero cold start)")
    # Grova Modal-resurspriser (USD) — justera efter din plan.
    ap.add_argument("--cpu", type=float, default=4.0)
    ap.add_argument("--mem", type=float, default=4.0, help="GB")
    ap.add_argument("--price-cpu-s", type=float, default=0.0000131, help="USD per CPU-core-sekund")
    ap.add_argument("--price-mem-s", type=float, default=0.00000222, help="USD per GB-sekund")
    args = ap.parse_args()

    if args.cold_wait > 0:
        print(f"Väntar {args.cold_wait}s för scale-to-zero...")
        time.sleep(args.cold_wait)

    # Cold start = första requesten efter idle.
    code, cold = one_request(args.url, args.path, args.file, args.model, args.timeout)
    print(f"Cold start: HTTP {code}  {cold:.2f}s")

    warm: list[float] = []
    errors = 0
    for i in range(args.n):
        code, dt = one_request(args.url, args.path, args.file, args.model, args.timeout)
        if code == 200:
            warm.append(dt)
        else:
            errors += 1
            print(f"  req {i}: HTTP {code}")

    if not warm:
        print("Inga lyckade warm-requests.")
        return

    p50 = percentile(warm, 0.50)
    p95 = percentile(warm, 0.95)
    avg = statistics.mean(warm)
    # Grov kostnad: single-stream wall-time × resurspris (ingen concurrency-vinst).
    cost_per_req = avg * (args.cpu * args.price_cpu_s + args.mem * args.price_mem_s)
    print(f"\nWarm ({len(warm)} ok, {errors} fel):")
    print(f"  p50 {p50:.3f}s   p95 {p95:.3f}s   avg {avg:.3f}s")
    print(f"  grov kostnad: ${cost_per_req * 1000:.3f} / 1000 req  (exkl. GPU-anrop)")


if __name__ == "__main__":
    main()
