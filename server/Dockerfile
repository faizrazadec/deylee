# The sync API, for any container host — Cloud Run, Fly, a plain VM, or Docker on
# the machine in front of you.
#
# Build from the REPOSITORY ROOT, not from server/:
#
#     docker build -f server/Dockerfile -t deylee-api .
#
# The context stays the repository root because that is what the deployment notes and
# cli_commands.md tell people to type. Every COPY below names a server/ path, so
# nothing outside server/ reaches a layer.

FROM python:3.14-slim AS build
# uv, not pip: it is what writes and reads uv.lock, so the image installs exactly the
# resolved set rather than whatever the index serves today.
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/
# Precompiled .pyc means the first request does not pay for byte-compiling, and the
# runtime user never needs to write into the image to cache it. copy, not hardlink,
# because the cache and the venv are on different layers.
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy
WORKDIR /app

# Manifests first, so a change to source alone reuses the resolved-dependency layer.
COPY server/pyproject.toml server/uv.lock ./
RUN uv sync --locked --no-install-project --no-dev

COPY server/src ./src
RUN uv sync --locked --no-dev

FROM python:3.14-slim
WORKDIR /app

# No apt layer. The slim image already carries ca-certificates, which is what verifies
# Google's JWKS endpoint over HTTPS.

# Only the environment and the sources. No uv, no lockfile, no wheel cache.
# The venv records the project as an editable install at /app/src, so both paths have
# to land where the build stage left them.
COPY --from=build /app/.venv /app/.venv
COPY --from=build /app/src /app/src

# Without this the process listens on loopback only, and nothing outside the
# container — including the platform's health check — can reach it.
ENV HOST=0.0.0.0
# A default, not a decision. Most managed hosts inject PORT and expect the process
# to honour it; `docker run -e PORT=…` does the same locally.
ENV PORT=8080
EXPOSE 8080

# Runs as a normal user, and deliberately does not own /app: nothing here needs to
# write to its own image, and the bytecode is already compiled, so read-only is enough.
RUN useradd --create-home --shell /usr/sbin/nologin deylee
USER deylee

# Asks /health over bash's own TCP redirection rather than curl. The slim image
# carries neither curl nor wget, and installing one to answer a health check would
# add runtime attack surface to fix a reporting gap. Reads PORT so the check follows
# the port the process was actually told to listen on.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD bash -c 'exec 3<>/dev/tcp/127.0.0.1/${PORT:-8080} \
        && printf "GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" >&3 \
        && head -1 <&3 | grep -q " 200 "'

# The venv's interpreter by absolute path: no activation script, no PATH to get wrong.
CMD ["/app/.venv/bin/python", "-m", "deylee_api"]
