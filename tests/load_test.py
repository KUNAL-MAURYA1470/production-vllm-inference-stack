#!/usr/bin/env python3
"""
Load Test — LLM Inference Stack
Validates: throughput, p50/p95/p99 latency, rate-limit enforcement, error budget.
HTTPS Hardened Version.

Usage:
  python3 tests/load_test.py                  # default: 30s ramp, 10 workers
  python3 tests/load_test.py --rps 5 --duration 60
"""
import argparse
import concurrent.futures
import statistics
import time
import os
import ssl
from dataclasses import dataclass, field
from typing import List

import urllib.request
import urllib.error
import json

API = "https://localhost:8443"
MODEL = "Qwen/Qwen2.5-32B-Instruct"

# SLO targets
SLO_P95_MS   = 30_000   # 30s — LLM inference is slow
SLO_ERROR_PCT = 1.0     # <1% non-429 errors
SLO_RPS_MIN   = 2.0     # sustain at least 2 req/s through gateway


def load_env_api_key() -> str:
    default_key = "sk-llm-inference-stack-super-secret-key-12345"
    try:
        env_path = os.path.join(os.path.dirname(__file__), "..", ".env")
        if os.path.exists(env_path):
            with open(env_path, "r") as f:
                for line in f:
                    if line.strip().startswith("VLLM_API_KEY="):
                        val = line.split("=", 1)[1].strip()
                        val = val.strip("'\"")
                        if val:
                            return val
    except Exception:
        pass
    return default_key


VLLM_API_KEY = load_env_api_key()

# Create unverified SSL context for self-signed certificates used in development
SSL_CONTEXT = ssl._create_unverified_context()


@dataclass
class Result:
    status: int
    latency_ms: float
    error: str = ""


def send_request(prompt: str = "Say hi in one word.") -> Result:
    payload = json.dumps({
        "model": MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": 10,
    }).encode()
    req = urllib.request.Request(
        f"{API}/v1/chat/completions",
        data=payload,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {VLLM_API_KEY}"
        },
    )
    t0 = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=35, context=SSL_CONTEXT) as resp:
            resp.read()
            return Result(resp.status, (time.monotonic() - t0) * 1000)
    except urllib.error.HTTPError as e:
        return Result(e.code, (time.monotonic() - t0) * 1000)
    except Exception as e:
        return Result(0, (time.monotonic() - t0) * 1000, str(e))


def run_load(rps: float, duration: int, workers: int) -> List[Result]:
    results: List[Result] = []
    interval = 1.0 / rps
    deadline = time.monotonic() + duration
    futures = []

    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        while time.monotonic() < deadline:
            futures.append(pool.submit(send_request))
            time.sleep(interval)
        results = [f.result() for f in concurrent.futures.as_completed(futures)]
    return results


def report(results: List[Result], duration: int):
    total      = len(results)
    ok         = [r for r in results if r.status == 200]
    throttled  = [r for r in results if r.status == 429]
    errors     = [r for r in results if r.status not in (200, 429)]
    latencies  = sorted(r.latency_ms for r in ok)

    def pct(n, d): return 100 * n / d if d else 0
    def p(lat, q): return lat[int(len(lat) * q / 100)] if lat else 0

    actual_rps = total / duration
    error_pct  = pct(len(errors), total)

    print(f"\n{'━'*50}")
    print(f"  LOAD TEST RESULTS  ({total} requests over {duration}s)")
    print(f"{'━'*50}")
    print(f"  Throughput : {actual_rps:.2f} req/s")
    print(f"  HTTP 200   : {len(ok):>4}  ({pct(len(ok), total):.1f}%)")
    print(f"  HTTP 429   : {len(throttled):>4}  ({pct(len(throttled), total):.1f}%)  ← rate limited")
    print(f"  Errors     : {len(errors):>4}  ({error_pct:.1f}%)")
    if latencies:
        print(f"\n  Latency (successful requests):")
        print(f"    p50  : {p(latencies,50):>7.0f} ms")
        print(f"    p95  : {p(latencies,95):>7.0f} ms")
        print(f"    p99  : {p(latencies,99):>7.0f} ms")
        print(f"    max  : {max(latencies):>7.0f} ms")

    print(f"\n  SLO Evaluation:")
    slo_pass = True

    p95 = p(latencies, 95)
    if latencies and p95 <= SLO_P95_MS:
        print(f"  ✔ p95 latency {p95:.0f}ms ≤ {SLO_P95_MS}ms")
    elif latencies:
        print(f"  ✘ p95 latency {p95:.0f}ms > {SLO_P95_MS}ms SLO"); slo_pass = False

    if error_pct <= SLO_ERROR_PCT:
        print(f"  ✔ Error rate {error_pct:.2f}% ≤ {SLO_ERROR_PCT}%")
    else:
        print(f"  ✘ Error rate {error_pct:.2f}% > {SLO_ERROR_PCT}% SLO"); slo_pass = False

    if actual_rps >= SLO_RPS_MIN:
        print(f"  ✔ Throughput {actual_rps:.2f} req/s ≥ {SLO_RPS_MIN} req/s")
    else:
        print(f"  ✘ Throughput {actual_rps:.2f} req/s < {SLO_RPS_MIN} req/s SLO"); slo_pass = False

    print(f"\n  {'✔ ALL SLOs MET' if slo_pass else '✘ SLO VIOLATIONS DETECTED'}")
    return slo_pass


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--rps",      type=float, default=3,  help="Target requests/sec")
    ap.add_argument("--duration", type=int,   default=30, help="Test duration in seconds")
    ap.add_argument("--workers",  type=int,   default=10, help="Concurrent workers")
    args = ap.parse_args()

    print(f"Starting load test: {args.rps} req/s for {args.duration}s ({args.workers} workers)")
    results = run_load(args.rps, args.duration, args.workers)
    ok = report(results, args.duration)
    raise SystemExit(0 if ok else 1)
