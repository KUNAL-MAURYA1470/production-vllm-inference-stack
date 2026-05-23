#!/usr/bin/env bash
# Observability Test — validates Prometheus scraping, metric presence, Grafana datasource
# Hardened Version: Routes queries via internal docker execution and HTTPS proxy
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

# Load GRAFANA_ADMIN_PASSWORD from .env if present
GRAFANA_PASS="adminpassword123"
if [ -f "$DIR/../.env" ]; then
  GRAFANA_PASS=$(grep -E "^GRAFANA_ADMIN_PASSWORD=" "$DIR/../.env" | cut -d= -f2- | tr -d '"' | tr -d "'" | tr -d ' ')
fi
GRAFANA_PASS=${GRAFANA_PASS:-admin}

GRAFANA="https://localhost:8443/grafana"
PASS=0; FAIL=0

pass() { echo -e "\033[32m✔ $*\033[0m"; PASS=$((PASS+1)); }
fail() { echo -e "\033[31m✘ $*\033[0m"; FAIL=$((FAIL+1)); }

# Prometheus is now internal. Query it via NGINX container.
prom_query() {
  docker exec nginx curl -sf --max-time 10 -G "http://prometheus:9090/api/v1/query" --data-urlencode "query=$1" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); r=d['data']['result']; print(r[0]['value'][1] if r else '')" 2>/dev/null || true
}

# ── 1. Prometheus targets health ─────────────────────────────────────────────
echo -e "\n\033[1m[1/4] PROMETHEUS TARGETS (Scraped Internally)\033[0m"
targets=$(docker exec nginx curl -sf --max-time 10 "http://prometheus:9090/api/v1/targets" | python3 -c "
import sys, json
data = json.load(sys.stdin)['data']['activeTargets']
for t in data:
    print(t['labels'].get('job','?'), t['health'])
")
for job in vllm node-exporter cadvisor alertmanager; do
  if echo "$targets" | grep -q "^$job up$"; then
    pass "Prometheus scraping $job (up)"
  else
    fail "Prometheus target $job not up — got: $(echo "$targets" | grep "$job" || echo 'missing')"
  fi
done

# ── 2. vLLM metrics present ───────────────────────────────────────────────────
echo -e "\n\033[1m[2/4] vLLM METRICS\033[0m"
declare -A METRICS=(
  ["vllm:num_requests_running"]="Active requests gauge"
  ["vllm:kv_cache_usage_perc"]="KV cache utilization"
  ["vllm:e2e_request_latency_seconds_count"]="Request latency counter"
  ["vllm:prompt_tokens_total"]="Prompt token counter"
  ["vllm:generation_tokens_total"]="Generation token counter"
)
for metric in "${!METRICS[@]}"; do
  val=$(prom_query "$metric")
  if [[ -n "$val" ]]; then
    pass "${METRICS[$metric]} ($metric = $val)"
  else
    fail "${METRICS[$metric]} — metric '$metric' not found in Prometheus"
  fi
done

# ── 3. Node / cAdvisor metrics ────────────────────────────────────────────────
echo -e "\n\033[1m[3/4] INFRASTRUCTURE METRICS\033[0m"
for metric in "node_cpu_seconds_total" "node_memory_MemAvailable_bytes" "container_cpu_usage_seconds_total"; do
  val=$(prom_query "$metric")
  if [[ -n "$val" ]]; then pass "$metric present"; else fail "$metric missing"; fi
done

# ── 4. Grafana datasource healthy ─────────────────────────────────────────────
echo -e "\n\033[1m[4/4] GRAFANA DATASOURCES\033[0m"

# Get data sources via HTTPS gateway
datasources_json=$(curl -k -sf --max-time 10 -u "admin:${GRAFANA_PASS}" "${GRAFANA}/api/datasources" || echo "")

if [[ -n "$datasources_json" ]]; then
  # 1. Check Prometheus datasource
  prom_ds_uid=$(echo "$datasources_json" | python3 -c "import sys,json; ds=json.load(sys.stdin); print(next((d['uid'] for d in ds if d['type'] == 'prometheus'), ''))" 2>/dev/null || echo "")
  if [[ -n "$prom_ds_uid" ]]; then
    ds_status=$(curl -k -sf --max-time 10 \
      -u "admin:${GRAFANA_PASS}" \
      "${GRAFANA}/api/datasources/proxy/uid/${prom_ds_uid}/api/v1/query?query=up" \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','?'))" 2>/dev/null || echo "error")
    if [[ "$ds_status" == "success" ]]; then
      pass "Grafana → Prometheus datasource is healthy"
    else
      fail "Grafana Prometheus datasource query failed (status: $ds_status)"
    fi
  else
    fail "Could not retrieve Grafana Prometheus datasource UID"
  fi

  # 2. Check Loki datasource
  loki_ds_uid=$(echo "$datasources_json" | python3 -c "import sys,json; ds=json.load(sys.stdin); print(next((d['uid'] for d in ds if d['type'] == 'loki'), ''))" 2>/dev/null || echo "")
  if [[ -n "$loki_ds_uid" ]]; then
    pass "Grafana → Loki log datasource is provisioned (UID: $loki_ds_uid)"
  else
    fail "Grafana Loki log datasource is missing"
  fi
else
  fail "Could not connect to Grafana API via HTTPS Gateway"
fi

# 3. Check vLLM Dashboard provisioning
dash=$(curl -k -sf --max-time 10 \
  -u "admin:${GRAFANA_PASS}" \
  "${GRAFANA}/api/search?query=vLLM" \
  | python3 -c "import sys,json; items=json.load(sys.stdin); print(len(items))" 2>/dev/null || echo "0")
if [ "$dash" -gt 0 ]; then
  pass "vLLM dashboard provisioned in Grafana"
else
  fail "vLLM dashboard not found in Grafana"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "\n\033[1m━━━ OBSERVABILITY RESULTS ━━━\033[0m"
echo -e "  \033[32mPASS: $PASS\033[0m  \033[31mFAIL: $FAIL\033[0m"
if [ "$FAIL" -eq 0 ]; then
  echo -e "\033[32mObservability stack fully operational.\033[0m"
else
  echo -e "\033[31m$FAIL observability check(s) failed.\033[0m"
  exit 1
fi
