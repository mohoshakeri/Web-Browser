FROM debian:bookworm-slim

# Build-only env — keep this block stable so apt/pip layers stay cached
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Heavy system deps — rebuild only when this list changes
RUN apt-get update && apt-get install -y --no-install-recommends \
    chromium \
    xvfb \
    x11-utils \
    openbox \
    x11vnc \
    novnc \
    websockify \
    nginx \
    curl \
    python3 \
    python3-pip \
    python3-venv \
    fonts-noto \
    fonts-noto-color-emoji \
    fonts-noto-core \
    ca-certificates \
    dbus-x11 \
    procps \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/nginx/sites-enabled/default \
    && mkdir -p /data/chromium /var/log/nginx /var/cache/nginx /var/lib/nginx \
        /var/lib/openbox \
    && printf '%s\n' \
        '<?xml version="1.0" encoding="UTF-8"?>' \
        '<openbox_menu xmlns="http://openbox.org/">' \
        '  <menu id="root-menu" label="Openbox"/>' \
        '</openbox_menu>' \
        > /var/lib/openbox/debian-menu.xml \
    && chmod 755 /data \
    && chmod 750 /var/log/nginx

RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

WORKDIR /opt/browser

# Python deps — rebuild only when requirements.txt changes
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# App/config files last — small edits skip apt + pip
COPY nginx.conf start-browser.sh /opt/browser/
RUN chmod 755 /opt/browser/start-browser.sh

COPY auth.py /opt/browser/auth.py

# Runtime defaults (override with docker run -e). Placed late so tweaks
# do not invalidate apt/pip layers.
ENV DISPLAY=:99 \
    SCREEN_WIDTH=1920 \
    SCREEN_HEIGHT=1080 \
    SCREEN_DEPTH=24 \
    VNC_PORT=5900 \
    WEBSOCKIFY_PORT=6080 \
    AUTH_PORT=8090 \
    CHROME_PROFILE=/data/chromium \
    SESSION_TTL_DAYS=3 \
    COOKIE_SECURE=false \
    COOKIE_SAMESITE=lax

VOLUME ["/data"]

# Public HTTP entrypoint. Internal services listen on localhost.
EXPOSE 80

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS http://127.0.0.1:80/healthz || exit 1

CMD ["/opt/browser/start-browser.sh"]
