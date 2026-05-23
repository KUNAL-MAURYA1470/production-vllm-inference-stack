#!/usr/bin/env bash
# Generates a self-signed TLS certificate + key for NGINX.
# Output: nginx/certs/nginx.crt  nginx/certs/nginx.key
# Valid for 825 days (macOS/Chrome max for self-signed).

set -euo pipefail

CERT_DIR="$(cd "$(dirname "$0")" && pwd)/certs"
mkdir -p "$CERT_DIR"

openssl req -x509 -nodes \
  -newkey rsa:2048 \
  -days 825 \
  -keyout "$CERT_DIR/nginx.key" \
  -out    "$CERT_DIR/nginx.crt" \
  -subj   "/CN=localhost/O=LLM Inference Stack" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"

chmod 600 "$CERT_DIR/nginx.key"
echo "Certificates written to $CERT_DIR"
