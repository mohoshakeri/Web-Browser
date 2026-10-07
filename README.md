# Web Browser (Chromium + noVNC)

Chromium in Docker with browser access over noVNC. Only the nginx HTTP port is exposed; VNC and host filesystem paths are not. When `ACCESS_PASSWORD` is set, a FastAPI layer handles login and session cookies before the remote browser session is reachable.

## Files

| File | Role |
| --- | --- |
| `Dockerfile` | Image and dependencies |
| `start-browser.sh` | Starts Xvfb / Chromium / VNC / websockify / auth / nginx |
| `auth.py` | Authentication and sessions (FastAPI) |
| `nginx.conf` | Reverse proxy and path protection |
| `requirements.txt` | Python packages |
| `.env.sample` | Sample environment variables |

## Architecture

```
Browser (you)
    │
    ▼
nginx :80          ← only public entrypoint
    │
    ├── /login /logout /auth/*  → FastAPI (auth + session)
    ├── /websockify             → websockify → x11vnc (localhost only)
    └── /vnc.html + assets      → noVNC files (no directory listing)
```

## Install & run

```bash
cp .env.sample .env
# Change ACCESS_PASSWORD and SESSION_SECRET

docker build -t web-browser .
docker run -d --name web-browser \
  --env-file .env \
  -p 8080:80 \
  -v browser-chrome-data:/data \
  --shm-size=256m \
  --security-opt no-new-privileges:true \
  web-browser
```

Open:

```text
http://localhost:8080
```

Here `8080` is the host port; the container listens on `80`.

Stop / remove:

```bash
docker stop web-browser
docker rm web-browser
```

Logs:

```bash
docker logs -f web-browser
```

## Environment variables

| Variable | Default | Description |
| --- | --- | --- |
| `ACCESS_PASSWORD` | empty | If set, VNC/noVNC access requires login |
| `SESSION_SECRET` | random at start* | Signs session cookies; set a fixed strong value in production |
| `SESSION_TTL_DAYS` | `3` | Login session lifetime in days |
| `COOKIE_SECURE` | `false` | Set `true` when serving over HTTPS |
| `COOKIE_SAMESITE` | `lax` | `lax` / `strict` / `none` |
| `SCREEN_WIDTH` | `1920` | Virtual display width |
| `SCREEN_HEIGHT` | `1080` | Virtual display height |
| `SCREEN_DEPTH` | `24` | Xvfb color depth |
| `CHROME_PROFILE` | `/data/chromium` | Chromium profile path inside the container |

\* If `SESSION_SECRET` is empty, a new key is generated on each container start and previous sessions become invalid.

Full sample: [`.env.sample`](.env.sample)

## Auth & sessions

1. If `ACCESS_PASSWORD` is empty, access is open (private networks only).
2. If a password is set:
   - nginx checks FastAPI via `auth_request` before serving the UI or websocket.
   - A successful login sets an `HttpOnly` cookie named `browser_session`.
   - Cookie lifetime is `SESSION_TTL_DAYS` (default 3 days).
3. Logout: `/logout`

## Persist Chromium session (volume / disk)

The browser profile (site logins, cookies, Local Storage, extensions, …) lives under `/data/chromium`. Mount `/data` to keep it across restarts.

### Bind mount on the host

```bash
mkdir -p ./data
docker run -d --name web-browser \
  --env-file .env \
  -p 8080:80 \
  -v "$(pwd)/data:/data" \
  --shm-size=256m \
  web-browser
```

Data stays in `./data/chromium`.

### Notes

- Each pod uses `/data/chromium/<pod-name>/`. A new pod name uses a separate profile.
- Prefer **1 replica** if you want one shared browser session; more replicas = separate profiles.
- If tabs crash, raise shared memory (`shm`) to `512Mi` / `1Gi` in the Rancher workload.
- For backups, stop the workload first, then copy the volume.

## Security

- Only port `80` (nginx) is exposed; `x11vnc` and `websockify` listen on localhost.
- websockify does not serve static files; the UI comes only through controlled nginx paths.
- `autoindex` is off and sensitive path patterns are blocked.
- Basic security headers are set on nginx.
- Passwords are compared with `hmac.compare_digest`; cookies are signed with `itsdangerous`.

On the public internet, put TLS in front and set `COOKIE_SECURE=true`.

## Rancher / Kubernetes

nginx listens on container port `80`. Auth is internal on `8090` (localhost only).

### Workload

| Setting | Value |
| --- | --- |
| Container port | `80` |
| Service port / targetPort | `80` / `80` |
| Ingress backend | Service port `80`, protocol `HTTP` |
| Readiness / liveness | HTTP GET `/healthz` on port `80` |
| Replicas | `1` |
| Image pull | `Always` or a new image tag each deploy |

The hosting proxy must support WebSocket upgrades for `/websockify`. For long sessions, configure its WebSocket timeouts appropriately.

Public HTTPS terminates at the hosting proxy; set `COOKIE_SECURE=true`. Internal ports `8090` (auth), `6080` (websockify), and `5900` (VNC) must not be published.

`/healthz` checks nginx availability. It does not check authentication, VNC, or public routing.

Routine nginx and auth access logs are disabled. Startup reports readiness once; nginx/auth warnings and errors remain in the container logs. Chromium output is stored in `/tmp/chromium.log` and VNC output in `/tmp/x11vnc.log`; these files are temporary and are lost when the container is replaced. Chromium startup failures and restart notices remain visible in the container logs.
