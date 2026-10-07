#!/bin/bash
set -euo pipefail

AUTH_PORT="${AUTH_PORT:-8090}"
WEBSOCKIFY_PORT="${WEBSOCKIFY_PORT:-6080}"

render_nginx_config() {
    sed -e "s/__AUTH_PORT__/${AUTH_PORT}/g" \
        -e "s/__WEBSOCKIFY_PORT__/${WEBSOCKIFY_PORT}/g" \
        /opt/browser/nginx.conf > /etc/nginx/nginx.conf
    nginx -t -q
}

CHROMIUM_PID=""
NGINX_PID=""

# Keep separate profiles for each pod.
CHROME_PROFILE_ROOT="${CHROME_PROFILE:-/data/chromium}"
POD_NAME="${HOSTNAME:-$(hostname 2>/dev/null || echo pod)}"
CHROME_PROFILE="${CHROME_PROFILE_ROOT}/${POD_NAME}"

prepare_chrome_profile() {
    mkdir -p "$CHROME_PROFILE"
    # Stale locks from a previous pod on the same volume
    rm -f \
        "$CHROME_PROFILE/SingletonLock" \
        "$CHROME_PROFILE/SingletonCookie" \
        "$CHROME_PROFILE/SingletonSocket" \
        "$CHROME_PROFILE_ROOT/SingletonLock" \
        "$CHROME_PROFILE_ROOT/SingletonCookie" \
        "$CHROME_PROFILE_ROOT/SingletonSocket" \
        2>/dev/null || true
}

start_chromium() {
    prepare_chrome_profile
    chromium \
        --no-sandbox \
        --disable-dev-shm-usage \
        --disable-gpu \
        --disable-software-rasterizer \
        --user-data-dir="$CHROME_PROFILE" \
        --start-maximized \
        --no-first-run \
        --no-default-browser-check \
        --disable-session-crashed-bubble \
        --disable-infobars \
        about:blank >> /tmp/chromium.log 2>&1 &
    CHROMIUM_PID=$!
    sleep 1
    if ! kill -0 "$CHROMIUM_PID" 2>/dev/null; then
        echo "WARNING: Chromium exited immediately; see /tmp/chromium.log" >&2
    fi
}

cleanup() {
    local pids=(
        "${MONITOR_PID:-}"
        "${NGINX_PID:-}"
        "${AUTH_PID:-}"
        "${WEBSOCKIFY_PID:-}"
        "${VNC_PID:-}"
        "${CHROMIUM_PID:-}"
        "${OPENBOX_PID:-}"
        "${XVFB_PID:-}"
    )
    for pid in "${pids[@]}"; do
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
    done
    nginx -s quit 2>/dev/null || true
}
trap cleanup TERM INT

watch_chromium() {
    while true; do
        sleep 10
        if [[ -n "${CHROMIUM_PID:-}" ]] && ! kill -0 "$CHROMIUM_PID" 2>/dev/null; then
            echo "Chromium exited; restarting (see /tmp/chromium.log)" >&2
            start_chromium
        fi
    done
}

Xvfb "$DISPLAY" \
    -screen 0 "${SCREEN_WIDTH}x${SCREEN_HEIGHT}x${SCREEN_DEPTH}" \
    -nolisten tcp \
    +extension GLX \
    +render \
    -noreset &
XVFB_PID=$!

for _ in $(seq 1 50); do
    if xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done

if ! xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
    echo "Xvfb failed to start on $DISPLAY" >&2
    exit 1
fi

openbox &
OPENBOX_PID=$!

x11vnc \
    -display "$DISPLAY" \
    -forever \
    -shared \
    -rfbport "$VNC_PORT" \
    -localhost \
    -nopw \
    -noxdamage \
    -repeat \
    -xkb \
    -logfile /tmp/x11vnc.log &
VNC_PID=$!

start_chromium

websockify \
    --heartbeat=30 \
    "127.0.0.1:${WEBSOCKIFY_PORT}" \
    "127.0.0.1:${VNC_PORT}" &
WEBSOCKIFY_PID=$!

cd /opt/browser
uvicorn auth:app \
    --host 127.0.0.1 \
    --port "$AUTH_PORT" \
    --proxy-headers \
    --forwarded-allow-ips='*' \
    --log-level warning \
    --no-access-log &
AUTH_PID=$!

auth_ready=0
for _ in $(seq 1 150); do
    if curl -sf "http://127.0.0.1:${AUTH_PORT}/healthz" >/dev/null 2>&1; then
        auth_ready=1
        break
    fi
    if ! kill -0 "$AUTH_PID" 2>/dev/null; then
        echo "uvicorn (auth) exited before becoming ready" >&2
        wait "$AUTH_PID" || true
        exit 1
    fi
    sleep 0.2
done

if [[ "$auth_ready" -ne 1 ]]; then
    echo "auth service did not become ready on 127.0.0.1:${AUTH_PORT}" >&2
    exit 1
fi

render_nginx_config

watch_chromium &
MONITOR_PID=$!

nginx -g 'daemon off;' &
NGINX_PID=$!

nginx_ready=0
for _ in $(seq 1 50); do
    if curl -sf "http://127.0.0.1:80/healthz" >/dev/null 2>&1; then
        nginx_ready=1
        break
    fi
    if ! kill -0 "$NGINX_PID" 2>/dev/null; then
        echo "nginx exited during startup" >&2
        wait "$NGINX_PID" || true
        exit 1
    fi
    sleep 0.2
done

if [[ "$nginx_ready" -ne 1 ]]; then
    echo "nginx is not responding on port 80" >&2
    exit 1
fi

echo "Browser ready on port 80" >&2

# Stay alive on nginx — Chromium crashes must not stop HTTP
wait "$NGINX_PID"
