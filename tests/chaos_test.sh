#!/usr/bin/env bash
# Chaos Test — resilience and auto-recovery validation
set -euo pipefail

# Load configuration from .env if it exists
DIR="$(cd "$(dirname "$0")" && pwd)"
VLLM_API_KEY="sk-llm-inference-stack-super-secret-key-12345"
if [ -f "$DIR/../.env" ]; then
  VLLM_API_KEY=$(grep -E "^VLLM_API_KEY=" "$DIR/../.env" | cut -d= -f2- | tr -d '"' | tr -d "'" | tr -d ' ')
fi

API="https://localhost:8443"
PASS=0; FAIL=0

pass() { echo -e "\033[32m✔ $*\033[0m"; PASS=$((PASS+1)); }
fail() { echo -e "\033[31m✘ $*\033[0m"; FAIL=$((FAIL+1)); }

wait_healthy() {
  local container=$1 timeout=${2:-60}
  local elapsed=0
  echo -n "  Waiting for $container to recover"
  while [ "$elapsed" -lt "$timeout" ]; do
    status=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "missing")
    health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}running{{end}}' "$container" 2>/dev/null || echo "missing")
    if [[ "$status" == "running" && "$health" != "unhealthy" && "$health" != "starting" ]]; then
      echo " (${elapsed}s)"; return 0
    fi
    sleep 3; elapsed=$((elapsed+3)); echo -n "."
  done
  echo " TIMEOUT"; return 1
}

api_ok() {
  local code; code=$(curl -k -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $VLLM_API_KEY" --max-time 5 "$API/v1/models" 2>/dev/null || echo "000")
  [[ "$code" == "200" ]]
}

# ── Pre-flight ────────────────────────────────────────────────────────────────
echo -e "\n\033[1m[PRE-FLIGHT] Baseline health check\033[0m"
if ! api_ok; then
  echo "Stack not healthy before chaos tests. Aborting."
  exit 1
fi
pass "Baseline API healthy"

# ── Test 1: NGINX restart recovery ───────────────────────────────────────────
echo -e "\n\033[1m[1/3] NGINX RESTART RECOVERY\033[0m"
echo "  Restarting nginx container..."
docker restart nginx >/dev/null
sleep 2
if wait_healthy nginx 30; then
  if api_ok; then
    pass "API recovered after NGINX restart"
  else
    fail "API not responding after NGINX restart"
  fi
else
  fail "NGINX did not recover within 30s"
fi

# ── Test 2: Prometheus restart ────────────────────────────────────────────────
echo -e "\n\033[1m[2/3] PROMETHEUS RESTART RECOVERY\033[0m"
echo "  Restarting prometheus container..."
docker restart prometheus >/dev/null
if wait_healthy prometheus 30; then
  # Prometheus has no Docker healthcheck — wait for port to be ready
  sleep 3
  prom_ok=$(docker exec nginx curl -s -o /dev/null -w "%{http_code}" http://prometheus:9090/-/healthy || echo "000")
  if [[ "$prom_ok" == "200" ]]; then
    pass "Prometheus recovered and healthy"
  else
    fail "Prometheus not healthy after restart (HTTP $prom_ok)"
  fi
else
  fail "Prometheus did not recover within 30s"
fi

# ── Test 3: Restart policy validation ────────────────────────────────────────
echo -e "\n\033[1m[3/3] RESTART POLICY VALIDATION\033[0m"
for svc in vllm nginx prometheus grafana; do
  policy=$(docker inspect --format='{{.HostConfig.RestartPolicy.Name}}' "$svc" 2>/dev/null || echo "unknown")
  if [[ "$policy" == "unless-stopped" ]]; then
    pass "$svc restart policy: $policy"
  else
    fail "$svc restart policy is '$policy' (want: unless-stopped)"
  fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "\n\033[1m━━━ CHAOS TEST RESULTS ━━━\033[0m"
echo -e "  \033[32mPASS: $PASS\033[0m  \033[31mFAIL: $FAIL\033[0m"
if [ "$FAIL" -eq 0 ]; then echo -e "\033[32mAll resilience checks passed.\033[0m"
else echo -e "\033[31m$FAIL resilience check(s) failed.\033[0m"; exit 1; fi
