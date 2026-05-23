#!/usr/bin/env bash
# SRE Test Suite — LLM Inference Stack
# Hardened Version: Validates isolated networks, API gateway TLS, API keys, JSON errors, and SLOs
set -euo pipefail

# Determine script directory
DIR="$(cd "$(dirname "$0")" && pwd)"

# Load configuration from .env if it exists
VLLM_API_KEY="sk-llm-inference-stack-super-secret-key-12345"
if [ -f "$DIR/../.env" ]; then
  # Read VLLM_API_KEY while stripping quotes or spaces
  VLLM_API_KEY=$(grep -E "^VLLM_API_KEY=" "$DIR/../.env" | cut -d= -f2- | tr -d '"' | tr -d "'" | tr -d ' ')
fi

API="https://localhost:8443"
MODEL="Qwen/Qwen2.5-32B-Instruct"

PASS=0; FAIL=0; WARN=0

# ── helpers ──────────────────────────────────────────────────────────────────
green() { echo -e "\033[32m✔ $*\033[0m"; }
red()   { echo -e "\033[31m✘ $*\033[0m"; }
yellow(){ echo -e "\033[33m⚠ $*\033[0m"; }

pass() { green "$1"; PASS=$((PASS+1)); }
fail() { red   "$1"; FAIL=$((FAIL+1)); }
warn() { yellow "$1"; WARN=$((WARN+1)); }

assert_http() {
  local label=$1 url=$2 expected=${3:-200} auth_header=${4:-"Authorization: Bearer $VLLM_API_KEY"}
  local code; code=$(curl -k -s -o /dev/null -w "%{http_code}" -H "$auth_header" --max-time 10 "$url")
  if [[ "$code" == "$expected" ]]; then
    pass "$label (HTTP $code)"
  else
    fail "$label — got $code, want $expected"
  fi
}

assert_contains() {
  local label=$1 url=$2 pattern=$3 auth_header=${4:-"Authorization: Bearer $VLLM_API_KEY"}
  local body; body=$(curl -k -s -H "$auth_header" --max-time 10 "$url")
  if echo "$body" | grep -q "$pattern"; then
    pass "$label"
  else
    fail "$label — pattern '$pattern' not found"
  fi
}

assert_latency() {
  local label=$1 url=$2 max_ms=$3 auth_header=${4:-"Authorization: Bearer $VLLM_API_KEY"}
  local ms; ms=$(curl -k -s -o /dev/null -w "%{time_total}" -H "$auth_header" --max-time 10 "$url" | awk '{printf "%d", $1*1000}')
  if [ "$ms" -le "$max_ms" ]; then
    pass "$label (${ms}ms ≤ ${max_ms}ms)"
  else
    warn "$label — ${ms}ms > ${max_ms}ms SLO"
  fi
}

# ── 1. AVAILABILITY ───────────────────────────────────────────────────────────
echo -e "\n\033[1m[1/5] AVAILABILITY (via NGINX HTTPS Gateway)\033[0m"
assert_http  "NGINX Gateway health endpoint"   "$API/health"
assert_http  "OpenWebUI via HTTPS root"         "$API/" 200 "Authorization: None"
assert_http  "Models list endpoint"             "$API/v1/models"
assert_http  "Grafana UI via HTTPS proxy"       "$API/grafana/api/health" 200 "Authorization: None"
assert_contains "Model registered in API"      "$API/v1/models" "$MODEL"

# Test internal Prometheus scraping (Prometheus itself is unexposed)
prom_code=$(docker exec nginx curl -s -o /dev/null -w "%{http_code}" http://prometheus:9090/-/healthy || echo "000")
if [[ "$prom_code" == "200" ]]; then
  pass "Prometheus UI reachable inside internal network (HTTP 200)"
else
  fail "Prometheus UI internal check failed (HTTP $prom_code)"
fi

# Test internal Loki server (Loki itself is unexposed)
loki_code=$(docker exec nginx curl -s -o /dev/null -w "%{http_code}" http://loki:3100/ready || echo "000")
if [[ "$loki_code" == "200" ]]; then
  pass "Loki logs engine reachable inside internal network (HTTP 200)"
else
  fail "Loki logs engine internal check failed (HTTP $loki_code)"
fi

# ── 2. LATENCY SLOs ──────────────────────────────────────────────────────────
echo -e "\n\033[1m[2/5] LATENCY SLOs\033[0m"
assert_latency "Health check p99 < 200ms"       "$API/health"       200
assert_latency "Models list < 500ms"            "$API/v1/models"    500
assert_latency "Grafana UI check < 500ms"       "$API/grafana/api/health" 500 "Authorization: None"

# ── 3. RATE LIMITING ─────────────────────────────────────────────────────────
echo -e "\n\033[1m[3/5] RATE LIMITING (NGINX 10 req/s, burst=20)\033[0m"
echo "  Sending 25 rapid requests..."
rate_429=0; rate_ok=0
json_error_valid=0
for i in $(seq 1 25); do
  # Retrieve both HTTP code and body for validation
  response=$(curl -k -s -w "\n%{http_code}" -H "Authorization: Bearer $VLLM_API_KEY" --max-time 5 "$API/v1/models")
  body=$(echo "$response" | head -n -1)
  code=$(echo "$response" | tail -n 1)
  
  if [[ "$code" == "429" ]]; then
    rate_429=$((rate_429+1))
    # Validate the body is the custom JSON error we designed
    if echo "$body" | grep -q "rate_limit_error" && echo "$body" | grep -q "Too many requests"; then
      json_error_valid=$((json_error_valid+1))
    fi
  else
    rate_ok=$((rate_ok+1))
  fi
done
echo "  Results: ${rate_ok} OK, ${rate_429} rate-limited"
if [ "$rate_429" -gt 0 ]; then
  pass "Rate limiting is active (${rate_429}/25 requests throttled)"
  if [ "$json_error_valid" -eq "$rate_429" ]; then
    pass "Custom JSON 429 response validated successfully"
  else
    fail "Custom JSON 429 response invalid or missing (valid count: $json_error_valid / $rate_429)"
  fi
else
  warn "No 429s observed — burst zone may have absorbed all requests"
fi

# ── 4. SECURITY & ISOLATION ──────────────────────────────────────────────────
echo -e "\n\033[1m[4/5] SECURITY & ISOLATION\033[0m"

# 1. Metrics block
code=$(curl -k -s -o /dev/null -w "%{http_code}" --max-time 5 "$API/metrics")
if [[ "$code" == "403" ]]; then
  pass "Metrics endpoint blocked externally (HTTP 403)"
else
  fail "Metrics endpoint exposed! Got $code (want 403)"
fi

# 2. Authentication Enforcement
code=$(curl -k -s -o /dev/null -w "%{http_code}" --max-time 5 "$API/v1/models")
if [[ "$code" == "401" ]]; then
  pass "API request without credentials correctly rejected (HTTP 401)"
else
  fail "API request without credentials was not rejected! Got HTTP $code"
fi

code=$(curl -k -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer invalid-key" --max-time 5 "$API/v1/models")
if [[ "$code" == "401" ]]; then
  pass "API request with invalid credentials correctly rejected (HTTP 401)"
else
  fail "API request with invalid credentials was not rejected! Got HTTP $code"
fi

# 3. Port Isolation (None of the internal services should expose ports to the host)
for port_name in "vLLM (8000)" "OpenWebUI (8088)" "Prometheus (9090)" "Grafana (3000)" "Loki (3100)" "Alertmanager (9093)"; do
  port=$(echo "$port_name" | grep -oE "[0-9]+")
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 "http://localhost:$port/" 2>/dev/null || echo "000")
  if [[ "$code" == "000" ]]; then
    pass "Port isolation: $port_name not exposed directly to host"
  else
    fail "Security breach: $port_name reachable directly on host! (HTTP $code)"
  fi
done

# ── 5. CONTAINER HEALTH ───────────────────────────────────────────────────────
echo -e "\n\033[1m[5/5] CONTAINER HEALTH\033[0m"
for svc in vllm nginx prometheus grafana node-exporter cadvisor loki promtail alertmanager; do
  status=$(docker inspect --format='{{.State.Status}}' "$svc" 2>/dev/null || echo "missing")
  health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' "$svc" 2>/dev/null || echo "missing")
  if [[ "$status" == "running" ]]; then
    if [[ "$health" == "unhealthy" ]]; then
      fail "$svc: running but unhealthy"
    else
      pass "$svc: $status (health: $health)"
    fi
  else
    fail "$svc: $status"
  fi
done

# ── SUMMARY ───────────────────────────────────────────────────────────────────
echo -e "\n\033[1m━━━ RESULTS ━━━\033[0m"
echo -e "  \033[32mPASS: $PASS\033[0m  \033[31mFAIL: $FAIL\033[0m  \033[33mWARN: $WARN\033[0m"
if [ "$FAIL" -eq 0 ]; then
  echo -e "\033[32mAll critical checks passed.\033[0m"
else
  echo -e "\033[31m$FAIL critical check(s) failed.\033[0m"
  exit 1
fi
