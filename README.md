# Hardened Production-Grade LLM Inference Stack

An end-to-end, enterprise-ready, and highly secure LLM inference stack using **vLLM (ROCm/MI300X)**, **NGINX (HTTPS TLS Gateway)**, **OpenWebUI**, **Prometheus**, **Alertmanager**, **Grafana Loki**, and **Grafana**.

This project showcases SRE best practices, zero-trust network isolation, unified HTTPS proxying, API rate-limiting, custom JSON API errors, non-root/read-only container security, and log aggregation.

---

## 📁 Project Structure

```
llm-inference-stack/
├── docker-compose.yml       # Hardened multi-network isolated architecture
├── .env.example             # Template for API keys, passwords, and tokens
├── .gitignore
├── README.md                # Fast-start guide (this file)
├── RUNBOOK.md               # Unified SRE & DevOps Operational Manual
├── nginx/
│   ├── nginx.conf           # Secure HTTPS gateway with custom JSON error handlers
│   ├── gen-certs.sh         # Idempotent self-signed TLS cert generator
│   └── certs/               # Git-ignored TLS certs directory
├── prometheus/
│   ├── prometheus.yml       # Prometheus scrapes internal services only
│   ├── rules.yml            # Predefined SRE alerting rules (saturation, latency SLOs)
│   ├── alertmanager.yml     # Alertmanager alerting thresholds & webhook receivers
│   ├── loki-config.yml      # Grafana Loki logs ingestion configuration
│   └── promtail-config.yml  # Promtail container log shipping pipeline
├── grafana/
│   └── provisioning/
│       ├── datasources/
│       │   └── prometheus.yml # Auto-registers Prometheus & Loki datasources
│       └── dashboards/
│           ├── dashboards.yml
│           └── vllm-dashboard.json # Rich SRE dashboard with metrics, alerts, and live Loki logs
└── tests/
    ├── sre_test_suite.sh    # Validates HTTPS availability, JSON errors, key auth, and port blockages
    ├── load_test.py         # Thread-based load testing validating latency SLOs
    ├── observability_test.sh# Verifies internal metrics scrapers and datasource health
    └── chaos_test.sh        # Resilience and container self-healing validations
```

---

## 🚀 Easy End-to-End Steps to Run the Stack

Follow these three simple steps to start, verify, and monitor the entire stack:

### Step 1: Environment & TLS Certs Setup
Copy the environment file and generate the self-signed TLS certificates:

```bash
# 1. Copy env file
cp .env.example .env

# 2. Open .env and set your HF_TOKEN (Hugging Face)
# Set your VLLM_API_KEY to a secure token of your choice

# 3. Generate the TLS Certificates
bash nginx/gen-certs.sh
```

---

### Step 2: Start the Stack
Bring up the multi-container isolated cluster in the background:

```bash
docker compose up -d
```

> **Note:** On the first run, vLLM will take **3–6 minutes** to pull the images, download the 61 GiB Qwen2.5-32B weights, compile CUDA graphs, and warm up. 
> 
> Watch vLLM's startup logs:
> ```bash
> docker logs vllm --follow
> ```
> Once you see `Application startup complete.`, the stack is fully ready!

---

### Step 3: Run SRE Verifications
Execute the built-in automated verification tests to confirm the security, isolation, and SLO metrics of the stack:

```bash
# 1. Run Core SRE Tests (Availability, API Key Auth, Port Isolation, Custom JSON 429 Errors)
bash tests/sre_test_suite.sh

# 2. Run Observability Tests (Internal Scrapers, Loki logs & Grafana datasource validations)
bash tests/observability_test.sh

# 3. Run Load Test (Sustains 3 req/s under load to validate latencies vs SRE SLOs)
python3 tests/load_test.py
```

---

## 🔒 Service Entrypoints & Port Security

In a hardened production configuration, **all raw service ports are unexposed to the host** to prevent unauthorized access and telemetry leaks. All human interactions and API client connections are routed securely through the **NGINX HTTPS Gateway**:

| Service / Interface | Protocol | Port / URL | Access Detail |
|---|---|---|---|
| **Secure API Gateway** | HTTPS | `https://localhost:8443/v1/` | Requires `Authorization: Bearer <VLLM_API_KEY>` |
| **OpenWebUI Chat Web Interface** | HTTPS | `https://localhost:8443/` | Secure, authenticated frontend |
| **SRE Grafana Dashboards** | HTTPS | `https://localhost:8443/grafana/`| Metrics, Alerts, and live Loki logs |
| **vLLM Inference Engine** | HTTP (Internal) | `vllm:8000` | 🚫 Unexposed to host (Blocked) |
| **Prometheus Telemetry** | HTTP (Internal) | `prometheus:9090` | 🚫 Unexposed to host (Blocked) |
| **Loki Log Engine** | HTTP (Internal) | `loki:3100` | 🚫 Unexposed to host (Blocked) |
| **Alertmanager Rules** | HTTP (Internal) | `alertmanager:9093`| 🚫 Unexposed to host (Blocked) |

---

## 📊 Live Monitoring Showcase

When you access Grafana at `https://localhost:8443/grafana/` (log in with `admin` and the password set in your `.env`), the pre-provisioned **vLLM Inference Stack** dashboard displays:
1. **Model Metrics:** E2E Request Latency (P50/P95/P99), Prompt/Generation Token Throughput, Scheduler States (Running/Waiting requests), and KV Cache Utilizations.
2. **System Telemetry:** Host CPU/Memory, vLLM Container CPU/Memory, Network I/O, and Disk Read/Writes.
3. **SRE Alerting Status:** An active, interactive table displaying firing Prometheus alarms (e.g. KV Cache saturation, high latency, target downtime).
4. **Correlated Container Logs:** A live Loki-powered logs viewer consolidating raw vLLM engine states and NGINX Gateway requests side-by-side.

---

## 💡 Quick Manual Checks (Smoke Tests)

If you wish to run manual command-line smoke checks:

### 1. Test Gateway TLS Redirection (HTTP 301 Redirect)
```bash
curl -v http://localhost:8080/v1/models 2>&1 | grep "< HTTP\|Location:"
# Expected: HTTP/1.1 301 Moved Permanently pointing to port 8443
```

### 2. Verify API Key Rejection (Expect: HTTP 401 Unauthorized)
```bash
curl -k https://localhost:8443/v1/models
# Expected: {"detail":"Unauthorized"}
```

### 3. Query Models with Secure Key (Expect: HTTP 200 OK)
```bash
# Set VLLM_API_KEY variable to match your .env configuration
VLLM_API_KEY="sk-llm-inference-stack-super-secret-key-12345"

curl -k https://localhost:8443/v1/models \
  -H "Authorization: Bearer $VLLM_API_KEY"
```

### 4. Trigger rate limiting and verify Custom JSON Gateway Error (Expect: HTTP 429)
Send rapid requests to models endpoint. NGINX will intercept the rate limit limit and return an OpenAI-compliant JSON error instead of standard HTML:
```bash
for i in {1..20}; do curl -k -s -H "Authorization: Bearer $VLLM_API_KEY" https://localhost:8443/v1/models; done
# Expected response during burst throttling:
# {"error": {"message": "Too many requests. Please retry later.", "type": "rate_limit_error", "code": 429}}
```

---

## 📖 SRE Runbook
For advanced architecture diagrams, recovery runbooks, GPU tuning details, telemetry metrics, and troubleshooting, read the **[SRE & DevOps Runbook](RUNBOOK.md)**.
