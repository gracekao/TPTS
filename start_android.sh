#!/system/bin/sh
set -eu

INSTALL_DIR="/data/local/tmp/TPTS"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DASHBOARD_URL="http://127.0.0.1:8080"

# /sdcard and other shared storage are mounted noexec, so run from /data/local/tmp/TPTS.
if [ "$SCRIPT_DIR" != "$INSTALL_DIR" ]; then
  if [ ! -f "$SCRIPT_DIR/proxy/tpts_backend_android_arm64" ]; then
    echo "[TPTS] Missing proxy/tpts_backend_android_arm64 next to this script."
    exit 1
  fi
  echo "[TPTS] Installing $SCRIPT_DIR -> $INSTALL_DIR ..."
  if ! { mkdir -p "$INSTALL_DIR" && cp -R "$SCRIPT_DIR/." "$INSTALL_DIR/"; } 2>/dev/null; then
    su 0 sh -c "mkdir -p '$INSTALL_DIR' && cp -R '$SCRIPT_DIR/.' '$INSTALL_DIR/'"
  fi
  exec sh "$INSTALL_DIR/start_android.sh"
fi

PROXY_DIR="$SCRIPT_DIR/proxy"
APP_DIR="$SCRIPT_DIR/app"

chmod 755 "$PROXY_DIR/tpts_backend_android_arm64" "$SCRIPT_DIR"/device_tools/* \
  "$SCRIPT_DIR"/stress_apk/Geekbench-*/geekbench_* 2>/dev/null || true

if [ ! -x "$PROXY_DIR/tpts_backend_android_arm64" ]; then
  echo "[TPTS] Missing Android backend binary: proxy/tpts_backend_android_arm64"
  exit 1
fi

if [ ! -f "$APP_DIR/index.html" ]; then
  echo "[TPTS] Missing app assets: app/index.html"
  echo "[TPTS] Copy the full TPTS folder (including app/) to device, then retry."
  exit 1
fi

pkill -f tpts_backend_android_arm64 2>/dev/null || true

mkdir -p "$SCRIPT_DIR/logs"
cd "$PROXY_DIR"
echo "[TPTS] Starting Android local backend..."
nohup "$PROXY_DIR/tpts_backend_android_arm64" >"$SCRIPT_DIR/logs/backend.log" 2>&1 &

sleep 2

echo "[TPTS] Dashboard: $DASHBOARD_URL"
echo "[TPTS] In dashboard, set target IP to: local"
am start -a android.intent.action.VIEW -d "$DASHBOARD_URL" >/dev/null 2>&1 || true