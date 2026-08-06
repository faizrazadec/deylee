# The sync API, for any container host — Railway, Cloud Run, Fly, a plain VM.
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
RUN swift build --package-path server -c release --product DeyleeAPI

# Collect the runtime pieces into one place for a clean copy into the final image.
RUN mkdir -p /out && \
    cp "$(swift build --package-path server -c release --show-bin-path)/DeyleeAPI" /out/

FROM swift:6.0-noble-slim
WORKDIR /app

# Certificates for two different jobs: the system store to verify Google's JWKS
# endpoint over HTTPS, and Supabase's own CA to verify the database — Supabase
# signs Postgres with a root no public store carries.
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /out/DeyleeAPI /app/DeyleeAPI
COPY server/certs/supabase-prod-ca-2021.crt /app/certs/supabase-prod-ca-2021.crt
ENV DEYLEE_DB_CA_CERT=/app/certs/supabase-prod-ca-2021.crt

# Without this the process listens on loopback only, and nothing outside the
# container — including the platform's health check — can reach it.
ENV HOST=0.0.0.0
# Overridden by the platform. Railway and Cloud Run both inject PORT.
ENV PORT=8080
EXPOSE 8080

# Runs as a normal user: nothing here needs root, and a process that cannot write
# to its own image is one fewer thing to reason about.
RUN useradd --create-home --shell /usr/sbin/nologin deylee && chown -R deylee /app
USER deylee

CMD ["/app/DeyleeAPI"]
