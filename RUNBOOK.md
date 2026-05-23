# LLM Inference Stack — SRE & DevOps Runbook

**Stack:** vLLM (ROCm/MI300X) · NGINX (HTTPS TLS Gateway) · OpenWebUI · Prometheus · Grafana · Loki · Promtail · Alertmanager · node-exporter · cAdvisor  
**Model:** Qwen/Qwen2.5-32B-Instruct (61 GiB, bfloat16)  
**Last updated:** 2026-05-23  
**Author:** SRE / ML Platform Engineering

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [Step 1 — Repository & Environment Setup](#3-step-1--repository--environment-setup)
4. [Step 2 — TLS Certificate Generation](#4-step-2--tls-certificate-generation)
5. [Step 3 — Bring the Stack Up](#5-step-3--bring-the-stack-up)
6. [Step 4 — Wait for vLLM to Be Ready](#6-step-4--wait-for-vllm-to-be-ready)
7. [Step 5 — Smoke Tests & Verification](#7-step-5--smoke-tests--verification)
8. [Step 6 — SRE Test Suite](#8-step-6--sre-test-suite)
9. [Step 7 — Observability Validation](#9-step-7--observability-validation)
10. [Step 8 — Load Testing](#10-step-8--load-testing)
11. [Step 9 — Chaos & Resilience Testing](#11-step-9--chaos--resilience-testing)
12. [Operational Runbook — Day 2](#12-operational-runbook--day-2)
13. [SLO Reference](#13-slo-reference)
14. [Challenges Faced & Solutions](#14-challenges-faced--solutions)

---

## 1. Architecture Overview

This project implements a hardened, highly isolated, enterprise-grade LLM inference platform. All internal services are shielded from direct host/public network access. NGINX acts as the unified **Secure HTTPS Gateway** and **API Reverse Proxy**, enforcing SSL/TLS termination, rate limiting, custom JSON API error handling, and security headers.

```
                  ┌──────────────────────────────────────────────┐
                  │              Internet / Client               │
                  └──────────────────────┬───────────────────────┘
                                         │
                                         ▼
                  ┌──────────────────────────────────────────────┐
                  │                 NGINX Gateway                │
                  │        • Port 8080: HTTP Redirect            │
                  │        • Port 8443: HTTPS Hardened TLS       │
                  │        • Rate Limiting: 10 req/s, burst=20   │
                  │        • Custom JSON Error Interception      │
                  └────┬─────────────────┬─────────────────┬─────┘
                       │                 │                 │
       [backend-net]   │                 │ [frontend-net]  │ [monitoring-net]
       (Internal Only) │                 │ (Internal Only) │ (Internal Only)
                       ▼                 ▼                 ▼
                 ┌───────────┐     ┌───────────┐     ┌───────────┐
                 │   vLLM    │     │ OpenWebUI │     │  Grafana  │
                 │   Port    │     │   Port    │     │   Port    │
                 │ 8000/v1/  │     │ 8080 (/)  │     │ 3000 (/g) │
                 └─────┬─────┘     └───────────┘     └─────▲─────┘
                       │                                   │
                       │             [monitoring-net]      │ Queries
                       └──────┐     (Internal Only)        │
                              ▼                            │
                       ┌────────────┐                      │
                       │ Prometheus │──────────────────────┘
                       │ Port 9090  │◄──────┐ Scrapes logs
                       └──────▲─────┘       │
                              │             │
                    Alerts    │             │
                              ▼             ▼
                       ┌────────────┐ ┌────────────┐ ┌────────────┐
                       │Alertmanager│ │    Loki    │◄│  Promtail  │
                       │ Port 9093  │ │ Port 3100  │ │  Shipping  │
                       └────────────┘ └────────────┘ └────────────┘
                              ▲ Scrapes            Tails /var/lib/docker/
                              │                      containers/*.log
                 ┌────────────┴────────────┐
                 │ node-exporter  cadvisor │
                 └─────────────────────────┘
```

### Key Security & Design Principles

* **Zero-Trust Network Isolation:** Services are grouped into four isolated bridge networks (`public-net`, `frontend-net`, `backend-net`, `monitoring-net`).
* **Unexposed Host Ports:** All service ports (except NGINX `8080` & `8443`) are completely hidden from the host interface. No direct access to vLLM (`8000`), OpenWebUI (`8088`), Prometheus (`9090`), Grafana (`3000`), Loki (`3100`), or Alertmanager (`9093`) is possible from the outside.
* **Unified HTTPS TLS Termination:** NGINX handles SSL/TLS termination for both human operators (OpenWebUI at `https://localhost:8443/`, Grafana at `https://localhost:8443/grafana/`) and API clients (vLLM at `https://localhost:8443/v1/`).
* **OpenAI-Compliant JSON API Errors:** NGINX intercepts `429` (Rate Limited), `502` (Bad Gateway), and `503` (Service Unavailable) errors, returning beautiful JSON payloads instead of default HTML pages.
* **Non-Root & Read-Only Hardening:** Containers run as non-root where supported and enforce `read_only: true` filesystems with `tmpfs` ephemeral mounts to defend against persistent filesystem injection.
* **End-to-End Authentication:** vLLM is secured with a real `VLLM_API_KEY` defined in `.env`. OpenWebUI and testing suites are configured to authenticate automatically using this secure token.
* **Complete Observability:** Logs are aggregated via Loki and Promtail, and alerts are configured via Alertmanager with dedicated dashboards displaying metrics, active alert tables, and correlated container logs.

---

## 2. Prerequisites

### 2.1 System Requirements

| Requirement | Check command | Expected |
|---|---|---|
| Docker ≥ 24 | `docker --version` | `Docker version 24+` |
| Docker Compose v2 | `docker compose version` | `v2.x.x` |
| AMD GPU (MI300X) | `rocm-smi` | GPU listed, no errors |
| `/dev/kfd` present | `ls /dev/kfd` | File exists |
| `/dev/dri` present | `ls /dev/dri` | `card*`, `renderD*` entries |
| ROCm drivers | `rocm-smi --showmeminfo vram` | VRAM reported |
| Internet access | `curl -I https://huggingface.co` | HTTP 200 |

### 2.2 HuggingFace Access

The model `Qwen/Qwen2.5-32B-Instruct` requires a HuggingFace account with access granted.

1. Request access to `Qwen/Qwen2.5-32B-Instruct` at https://huggingface.co/Qwen/Qwen2.5-32B-Instruct
2. Generate a token at https://huggingface.co/settings/tokens (read scope is sufficient)

### 2.3 Disk Space

| Item | Size |
|---|---|
| Docker images (all 10) | ~12 GB |
| Model weights (`hf_cache` volume) | ~61 GB |
| Prometheus + Loki DBs (15-day retention) | ~5–10 GB |
| **Total Recommended** | **~85 GB** |

---

## 3. Step 1 — Repository & Environment Setup

Copy `.env.example` to `.env` and fill in the required keys:

```bash
cp .env.example .env
```

Edit `.env` and populate:

```ini
# Hugging Face token (required to download Qwen/Qwen2.5-32B-Instruct)
HF_TOKEN=hf_your_actual_token_here

# Grafana admin password
GRAFANA_ADMIN_PASSWORD=choose_a_strong_password

# Secure API Key for vLLM and OpenWebUI authentication
VLLM_API_KEY=sk-llm-inference-stack-super-secret-key-12345
```

---

## 4. Step 2 — TLS Certificate Generation

NGINX terminates TLS on port 8443. Run the generator to produce the self-signed certificate:

```bash
bash nginx/gen-certs.sh
```

This generates `nginx/certs/nginx.crt` and `nginx/certs/nginx.key` (RSA 2048-bit, 825 days validity, covering `localhost` and `127.0.0.1`).

---

## 5. Step 3 — Bring the Stack Up

```bash
docker compose up -d
```

This starts all 10 containers in perfect topological order:
1. `loki`, `prometheus`, `alertmanager`, `node-exporter`, `cadvisor` start up.
2. `vllm` starts and downloads/loads the weights.
3. `openwebui` starts.
4. `promtail` starts scraping log directories.
5. `nginx` starts once `vllm` reports healthy.

---

## 6. Step 4 — Wait for vLLM to Be Ready

vLLM takes **3–6 minutes** on first boot to download, compile, and warm up CUDA graphs. Tailing logs is the best way to watch progress:

```bash
docker logs vllm --follow
```

The system is fully online when you see:
```
INFO:     Application startup complete.
INFO:     Uvicorn running on http://0.0.0.0:8000 (Press CTRL+C to quit)
```

Verify the health check from inside the gateway:
```bash
docker exec nginx curl -s http://vllm:8000/health
# Expected: {"status":"ok"}
```

---

## 7. Step 5 — Smoke Tests & Verification

### 7.1 Port Isolation Check (Expect: Connection Refused)

Validate that internal services are completely sealed from host network mapping:

```bash
curl -I http://localhost:8000/health
curl -I http://localhost:8088/
curl -I http://localhost:9090/
curl -I http://localhost:3000/
# All should fail with "Failed to connect" or "Connection refused"
```

### 7.2 API Access via Gateway (Expect: HTTP 401 Unauthorized)

Confirm that vLLM blocks requests lacking the secure API key:

```bash
curl -k https://localhost:8443/v1/models
# Expected: {"detail":"Unauthorized"} (HTTP 401)
```

### 7.3 API Access with Valid Auth (Expect: HTTP 200 OK)

Provide the secure API key to query model metadata:

```bash
curl -k https://localhost:8443/v1/models \
  -H "Authorization: Bearer sk-llm-inference-stack-super-secret-key-12345"
```

### 7.4 Chat Inference Test (Expect: Successful Completion response)

```bash
curl -k https://localhost:8443/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer sk-llm-inference-stack-super-secret-key-12345" \
  -d '{
    "model": "Qwen/Qwen2.5-32B-Instruct",
    "messages": [{"role": "user", "content": "Explain SRE in one sentence."}],
    "max_tokens": 50
  }'
```

### 7.5 Accessing Dashboards and UIs

* **OpenWebUI:** Open `https://localhost:8443/` in your browser. Bypass the self-signed warning, register an admin user, and begin chatting.
* **Grafana:** Open `https://localhost:8443/grafana/` in your browser. Log in with `admin` and your configured password to access the pre-configured SRE metrics & Loki logs dashboard.

---

## 8. Step 6 — SRE Test Suite

The automated `tests/sre_test_suite.sh` runs full availability, latency SLO, rate limiting, security isolation, custom JSON error structures, and container health checks.

```bash
bash tests/sre_test_suite.sh
```

**Key assertions validated by the suite:**
* NGINX exposes HTTPS TLS on port 8443; HTTP 8080 redirects to 8443.
* Direct ports are unexposed (3000, 9090, 8088, 8000, 3100, 9093).
* vLLM API rejects calls lacking the secure `VLLM_API_KEY`.
* Rapid bursts trigger NGINX rate-limiting (HTTP 429) returning custom JSON payloads containing `"rate_limit_error"`.
* Metrics endpoints (`/metrics`) return HTTP 403 Forbidden externally.

---

## 9. Step 7 — Observability Validation

Validate that metrics scrape configs, active alert definitions, and Loki log pipelines are operational:

```bash
bash tests/observability_test.sh
```

This script verifies:
1. Active scraping targets (`vllm`, `node-exporter`, `cadvisor`, `alertmanager`) show `up` in Prometheus.
2. Latency, token throughput, and KV cache utilization metrics are actively scraped.
3. Grafana is provisioned with both **Prometheus** (Metrics) and **Loki** (Logs) datasources.
4. The vLLM SRE dashboard is loaded and discoverable.

---

## 10. Step 8 — Load Testing

Use the Python load testing tool to evaluate throughput and latencies against defined SLOs:

```bash
python3 tests/load_test.py --rps 3 --duration 30 --workers 10
```

The script evaluates:
* **p95 Inference Latency:** Target $\le 30$ seconds.
* **Error Rate:** Target $< 1\%$ non-429 errors.
* **Throughput:** Target $\ge 2.0$ req/s sustained through the HTTPS Gateway.

---

## 11. Step 9 — Chaos & Resilience Testing

Validate container self-healing and service level recovery:

```bash
bash tests/chaos_test.sh
```

The script restarts the HTTPS Gateway (`nginx`) and metrics server (`prometheus`) under load and asserts recovery time remains below the 30-second SRE threshold, confirming the effectiveness of `unless-stopped` Docker policies.

---

## 12. Operational Runbook — Day 2

### Restarting the Stack Safely
```bash
docker compose restart
# Or restart a single service:
docker compose restart nginx
```

### Clean Hard Reset (Maintains Model Cache Volume)
```bash
docker compose down
docker compose up -d
```

### Cleaning Volumes (Warning: Triggers 61 GiB Model Re-download!)
```bash
docker compose down -v
```

### Continuous GPU Telemetry
```bash
watch -n 2 rocm-smi
```

### Inspecting Scraped Logs via CLI (Loki raw read)
```bash
docker exec -it loki wget -O- "http://localhost:3100/loki/api/v1/query_range?query={job=\"container-logs\"}&limit=10"
```

---

## 13. SLO Reference

| SLO | Target Threshold | Measured By |
|---|---|---|
| **API Gateway Availability** | 100% of Gateway containers online | `sre_test_suite.sh` |
| **p95 Inference Latency** | $\le 30$ seconds | `load_test.py` |
| **Error Rate (non-429)** | $< 1\%$ of overall traffic | `load_test.py` |
| **Log Ingestion Completeness** | Loki & Promtail green | `observability_test.sh` |
| **Service Recovery Time** | $< 30$ seconds | `chaos_test.sh` |

---

## 14. Challenges Faced & Solutions

### Challenge 1 — Unified Secure Routing & Port Isolation
**Problem:** Direct port mapping of vLLM (`8000`), OpenWebUI (`8088`), and Grafana (`3000`) bypasses security gateways, leaks raw telemetry, and exposes plain HTTP traffic to interception.
**Solution:** Removed all host mappings from compose configurations. Segmented traffic into three internal bridge networks and routed all human and API consumer requests through NGINX HTTPS on `8443`, enabling global TLS protection, consistent audit trailing, and deep security headers (HSTS, CSP).

### Challenge 2 — API Gateway Custom JSON Error Handlers
**Problem:** Typical gateways return default NGINX HTML error pages when a client is rate-limited (HTTP 429) or when the backend is offline/booting (HTTP 502/503). Standard LLM client libraries crash or fail to parse HTML responses.
**Solution:** Configured `proxy_intercept_errors on` and mapped standard HTTP error codes to custom NGINX location blocks. NGINX intercepts backend errors and returns standardized OpenAI-compliant JSON error bodies (e.g. `{"error": {"message": "Too many requests...", "type": "rate_limit_error", "code": 429}}`), providing seamless client library integration.

### Challenge 3 — Log Correlation & Observability Completion
**Problem:** Having metrics without log correlation hinders debugging. When a P95 latency spike occurs, SREs are forced to SSH into the host and run manual Docker commands to find vLLM and NGINX error logs.
**Solution:** Added Grafana Loki and Promtail to automatically capture, index, and ship docker logs. Loki was auto-provisioned as a datasource and integrated directly into the pre-defined SRE Grafana dashboard. SREs can now monitor GPU metrics, active Prometheus alerts, and raw container error logs in a single unified glass-pane dashboard.

### Challenge 4 — Filesystem Hardening vs. Service Writing
**Problem:** In production, container filesystems should be read-only to prevent dynamic script injection or malware persistence. However, NGINX and Prometheus require write access to various folders (caches, runs, pid files) and fail to start on raw read-only filesystems.
**Solution:** Configured `read_only: true` on hardened containers and specified ephemeral, limited-size `tmpfs` mounts (e.g. `/var/cache/nginx`, `/var/run`, `/tmp`) inside NGINX, Grafana, and Prometheus. This maintains standard daemon functionality while securing the underlying root directories.
