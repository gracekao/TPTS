#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROXY_DIR="$ROOT_DIR/proxy"
DASHBOARD_URL="http://localhost:8080"

# Archive tools do not always keep Unix exec bits.
chmod +x "$PROXY_DIR"/tpts_backend_linux_amd64 "$PROXY_DIR"/adb "$ROOT_DIR"/device_tools/* \
  "$ROOT_DIR"/stress_apk/Geekbench-*/geekbench_* 2>/dev/null || true

if [[ -x "$PROXY_DIR/tpts_backend_linux_amd64" ]]; then
  BACKEND_BIN="$PROXY_DIR/tpts_backend_linux_amd64"
elif [[ -x "$PROXY_DIR/tpts_backend" ]]; then
  BACKEND_BIN="$PROXY_DIR/tpts_backend"
else
  echo "[TPTS] Missing Linux backend binary: proxy/tpts_backend_linux_amd64"
  exit 1
fi

if [[ ! -x "$PROXY_DIR/adb" ]] && ! command -v adb >/dev/null 2>&1; then
  echo "[TPTS] Warning: adb not found (proxy/adb or PATH). Device connection will fail."
fi

if command -v pkill >/dev/null 2>&1; then
  pkill -f "$(basename "$BACKEND_BIN")" >/dev/null 2>&1 || true
fi

mkdir -p "$ROOT_DIR/logs"
cd "$PROXY_DIR"
echo "[TPTS] Starting backend: $BACKEND_BIN"
nohup "$BACKEND_BIN" >"$ROOT_DIR/logs/backend.log" 2>&1 &

for _ in $(seq 1 15); do
  if command -v curl >/dev/null 2>&1; then
    curl --silent --fail --max-time 1 "$DASHBOARD_URL/healthz" >/dev/null 2>&1 && break
  else
    sleep 2 && break
  fi
  sleep 1
done

echo "[TPTS] Dashboard: $DASHBOARD_URL"
echo "[TPTS] Backend log: logs/backend.log"
if command -v xdg-open >/dev/null 2>&1; then
  xdg-open "$DASHBOARD_URL" >/dev/null 2>&1 || true
fi