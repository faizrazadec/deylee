"""The one error shape every non-2xx response takes.

The clients parse `{"error": {"message": "<sentence>"}}` and nothing else, so
FastAPI's own `{"detail": ...}` is off-contract — as is its 422 for a body it cannot
validate, which the protocol spells 400. `app.py` installs handlers that route every
failure through `error_response` so there is exactly one place the envelope is built.
"""

from fastapi.responses import JSONResponse


class APIError(Exception):
    """A failure a handler gives up on, carrying the status and sentence to send.

    Raise this from a route. Middleware must *return* `error_response` instead:
    Starlette's exception handlers sit inside the middleware stack, so an APIError
    raised by a middleware escapes past them and becomes a bare 500.
    """

    def __init__(self, status: int, message: str, headers: dict[str, str] | None = None) -> None:
        super().__init__(message)
        self.status = status
        self.message = message
        self.headers = headers or {}


def error_response(
    status: int, message: str, headers: dict[str, str] | None = None
) -> JSONResponse:
    return JSONResponse({"error": {"message": message}}, status_code=status, headers=headers)
