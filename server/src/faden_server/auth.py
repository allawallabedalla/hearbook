"""Bearer token auth per docs/ARCHITEKTUR.md section 10.

Every endpoint except /api/v1/health requires `Authorization: Bearer
<FADEN_TOKEN>`.
"""

from __future__ import annotations

import hmac

from fastapi import Header, HTTPException


def make_auth_dependency(token: str):
    def require_token(authorization: str | None = Header(default=None)) -> None:
        if not authorization or not authorization.startswith("Bearer "):
            raise HTTPException(status_code=401, detail="missing bearer token")
        candidate = authorization.removeprefix("Bearer ")
        if not hmac.compare_digest(candidate, token):
            raise HTTPException(status_code=401, detail="invalid token")

    return require_token
