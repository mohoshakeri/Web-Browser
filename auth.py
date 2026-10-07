"""Auth gateway for noVNC access."""

from __future__ import annotations

import hashlib
import hmac
import os
import secrets
import time
from typing import Optional

from fastapi import FastAPI, Form, Request, Response, status
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from itsdangerous import BadSignature, SignatureExpired, URLSafeTimedSerializer

APP_NAME = "browser-gateway"
COOKIE_NAME = "browser_session"

ACCESS_PASSWORD = os.getenv("ACCESS_PASSWORD", "").strip()
SESSION_SECRET = os.getenv("SESSION_SECRET", "").strip() or secrets.token_hex(32)
SESSION_TTL_DAYS = max(1, int(os.getenv("SESSION_TTL_DAYS", "3")))
SESSION_MAX_AGE = SESSION_TTL_DAYS * 24 * 60 * 60
COOKIE_SECURE = os.getenv("COOKIE_SECURE", "false").lower() in {"1", "true", "yes"}
COOKIE_SAMESITE = os.getenv("COOKIE_SAMESITE", "lax").lower()
if COOKIE_SAMESITE not in {"lax", "strict", "none"}:
    COOKIE_SAMESITE = "lax"

serializer = URLSafeTimedSerializer(SESSION_SECRET, salt=APP_NAME)

app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)


def password_required() -> bool:
    return bool(ACCESS_PASSWORD)


def password_matches(candidate: str) -> bool:
    if not ACCESS_PASSWORD:
        return True
    expected = hashlib.sha256(ACCESS_PASSWORD.encode("utf-8")).digest()
    provided = hashlib.sha256(candidate.encode("utf-8")).digest()
    return hmac.compare_digest(expected, provided)


def create_session_token() -> str:
    return serializer.dumps(
        {
            "ok": True,
            "iat": int(time.time()),
            "nonce": secrets.token_hex(8),
        }
    )


def session_valid(token: Optional[str]) -> bool:
    if not password_required():
        return True
    if not token:
        return False
    try:
        data = serializer.loads(token, max_age=SESSION_MAX_AGE)
        return bool(data.get("ok"))
    except (BadSignature, SignatureExpired, TypeError, ValueError):
        return False


def set_session_cookie(response: Response, token: str) -> None:
    response.set_cookie(
        key=COOKIE_NAME,
        value=token,
        max_age=SESSION_MAX_AGE,
        httponly=True,
        secure=COOKIE_SECURE,
        samesite=COOKIE_SAMESITE,
        path="/",
    )


def clear_session_cookie(response: Response) -> None:
    response.delete_cookie(COOKIE_NAME, path="/")


LOGIN_PAGE = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Browser Access</title>
  <style>
    :root {{
      --bg: #0f1419;
      --panel: #1a2332;
      --text: #e7ecf3;
      --muted: #8b9bb4;
      --accent: #3d8bfd;
      --danger: #e35d6a;
      --border: #2a3548;
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      min-height: 100vh;
      display: grid;
      place-items: center;
      font-family: "Segoe UI", system-ui, sans-serif;
      background:
        radial-gradient(ellipse at top, #1c2a3f 0%, transparent 55%),
        var(--bg);
      color: var(--text);
    }}
    form {{
      width: min(100%, 360px);
      padding: 2rem;
      background: var(--panel);
      border: 1px solid var(--border);
      border-radius: 12px;
    }}
    h1 {{
      margin: 0 0 0.35rem;
      font-size: 1.35rem;
      font-weight: 600;
    }}
    p {{
      margin: 0 0 1.25rem;
      color: var(--muted);
      font-size: 0.9rem;
    }}
    label {{
      display: block;
      margin-bottom: 0.4rem;
      font-size: 0.85rem;
      color: var(--muted);
    }}
    input[type="password"] {{
      width: 100%;
      padding: 0.75rem 0.85rem;
      border: 1px solid var(--border);
      border-radius: 8px;
      background: #121821;
      color: var(--text);
      font-size: 1rem;
      margin-bottom: 1rem;
    }}
    input[type="password"]:focus {{
      outline: 2px solid color-mix(in srgb, var(--accent) 55%, transparent);
      border-color: var(--accent);
    }}
    button {{
      width: 100%;
      border: 0;
      border-radius: 8px;
      padding: 0.8rem 1rem;
      background: var(--accent);
      color: #fff;
      font-size: 0.95rem;
      font-weight: 600;
      cursor: pointer;
    }}
    button:hover {{ filter: brightness(1.08); }}
    .error {{
      margin: 0 0 1rem;
      padding: 0.65rem 0.75rem;
      border-radius: 8px;
      background: color-mix(in srgb, var(--danger) 18%, transparent);
      color: #ffb4bc;
      font-size: 0.85rem;
    }}
  </style>
</head>
<body>
  <form method="post" action="/login" autocomplete="current-password">
    <h1>Browser Access</h1>
    <p>Enter the access password to open the remote browser session.</p>
    {error}
    <label for="password">Password</label>
    <input id="password" name="password" type="password" required autofocus />
    <button type="submit">Continue</button>
  </form>
</body>
</html>
"""


@app.get("/healthz")
async def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/auth/verify")
async def auth_verify(request: Request) -> Response:
    """Used by nginx auth_request. 200 = allow, 401 = deny."""
    if session_valid(request.cookies.get(COOKIE_NAME)):
        return Response(status_code=status.HTTP_200_OK)
    return Response(status_code=status.HTTP_401_UNAUTHORIZED)


@app.get("/auth/status")
async def auth_status(request: Request) -> JSONResponse:
    return JSONResponse(
        {
            "authenticated": session_valid(request.cookies.get(COOKIE_NAME)),
            "password_required": password_required(),
            "session_ttl_days": SESSION_TTL_DAYS,
        }
    )


@app.get("/login", response_class=HTMLResponse)
async def login_page(request: Request) -> Response:
    if not password_required():
        return RedirectResponse(url="/", status_code=status.HTTP_302_FOUND)
    if session_valid(request.cookies.get(COOKIE_NAME)):
        return RedirectResponse(url="/", status_code=status.HTTP_302_FOUND)
    return HTMLResponse(LOGIN_PAGE.format(error=""))


@app.post("/login")
async def login(password: str = Form(...)) -> Response:
    if not password_required():
        return RedirectResponse(url="/", status_code=status.HTTP_303_SEE_OTHER)

    if not password_matches(password):
        time.sleep(0.4)
        html = LOGIN_PAGE.format(
            error='<div class="error">Invalid password. Try again.</div>'
        )
        return HTMLResponse(html, status_code=status.HTTP_401_UNAUTHORIZED)

    response = RedirectResponse(url="/", status_code=status.HTTP_303_SEE_OTHER)
    set_session_cookie(response, create_session_token())
    return response


@app.get("/logout")
@app.post("/logout")
async def logout() -> Response:
    response = RedirectResponse(url="/login", status_code=status.HTTP_303_SEE_OTHER)
    clear_session_cookie(response)
    return response


@app.get("/")
async def root(request: Request) -> Response:
    if password_required() and not session_valid(request.cookies.get(COOKIE_NAME)):
        return RedirectResponse(url="/login", status_code=status.HTTP_302_FOUND)
    return RedirectResponse(url="/vnc.html", status_code=status.HTTP_302_FOUND)
