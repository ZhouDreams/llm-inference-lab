import hmac
import os

from starlette.responses import JSONResponse


async def require_key(request, call_next):
    if request.url.path == "/health":
        return await call_next(request)

    key = os.environ.get("VLLM_API_KEY")
    if not key:
        return JSONResponse({"error": "API key is not configured"}, status_code=503)

    authorization = request.headers.get("authorization", "")
    if not hmac.compare_digest(authorization, f"Bearer {key}"):
        return JSONResponse({"error": "Unauthorized"}, status_code=401)

    return await call_next(request)
