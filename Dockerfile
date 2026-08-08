# The sync API, for any container host — Cloud Run, Fly, a plain VM, or Docker on
# the machine in front of you.
#
# Build from the REPOSITORY ROOT, not from server/:
#
#     docker build -f server/Dockerfile -t deylee-api .
#
# The API depends on DeyleeKit by path, so the root package has to be in the build
# context. That dependency is the whole point of the server being Swift: the
# day-boundary, overlap and midnight-split rules are the same code the Mac app
# runs, not a port of it that drifts.

FROM swift:6.0-noble AS build
# No SQLite package is needed any more. DeyleeKit used to link the system libsqlite3;
# it now compiles its own SQLite from the vendored amalgamation (CSQLCipher), as plain
# SQLite on Linux — the codec is Apple-only, because the server never opens a store.
# One fewer build and runtime dependency as a result.
WORKDIR /src

# Manifests first, so a change to source alone reuses the resolved-dependency layer.
COPY Package.swift ./
COPY server/Package.swift server/Package.resolved ./server/
# The root manifest declares the macOS app target too, and SwiftPM validates that a
# declared target's directory exists even when nothing asks it to build one. These
# are never compiled here — Linux has no AppKit — they simply have to be present.
COPY Sources ./Sources
COPY Resources ./Resources
RUN swift package --package-path server resolve

COPY server/Sources ./server/Sources
# The test target too, even though nothing here runs it. SwiftPM validates every
# target in the manifest before building any of them, and a test target whose
# directory is absent does not resolve to nothing — it falls back to searching, finds
# the executable's sources, and fails with "overlapping sources".
COPY server/Tests ./server/Tests
RUN swift build --package-path server -c release --product DeyleeAPI

# Collect the runtime pieces into one place for a clean copy into the final image.
RUN mkdir -p /out && \
    cp "$(swift build --package-path server -c release --show-bin-path)/DeyleeAPI" /out/

FROM swift:6.0-noble-slim
WORKDIR /app

# Certificates for two different jobs: the system store to verify Google's JWKS
# endpoint over HTTPS, and Supabase's own CA to verify the database — Supabase
# signs Postgres with a root no public store carries.
# Certificates for two different jobs: the system store to verify Google's JWKS
# endpoint over HTTPS, and Supabase's own CA below to verify the database.
#
# Only certificates now. SQLite is compiled into the binary from the vendored
# amalgamation, so there is no libsqlite3 shared library to carry at runtime.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /out/DeyleeAPI /app/DeyleeAPI
COPY server/certs/supabase-prod-ca-2021.crt /app/certs/supabase-prod-ca-2021.crt
ENV DEYLEE_DB_CA_CERT=/app/certs/supabase-prod-ca-2021.crt

# Without this the process listens on loopback only, and nothing outside the
# container — including the platform's health check — can reach it.
ENV HOST=0.0.0.0
# A default, not a decision. Most managed hosts inject PORT and expect the process
# to honour it; `docker run -e PORT=…` does the same locally.
ENV PORT=8080
EXPOSE 8080

# Runs as a normal user: nothing here needs root, and a process that cannot write
# to its own image is one fewer thing to reason about.
RUN useradd --create-home --shell /usr/sbin/nologin deylee && chown -R deylee /app
USER deylee

# Asks /health over bash's own TCP redirection rather than curl. The slim image
# carries neither curl nor wget, and installing one to answer a health check would
# add runtime attack surface to fix a reporting gap. Reads PORT so the check follows
# the port the process was actually told to listen on.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD bash -c 'exec 3<>/dev/tcp/127.0.0.1/${PORT:-8080} \
        && printf "GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" >&3 \
        && head -1 <&3 | grep -q " 200 "'

CMD ["/app/DeyleeAPI"]
