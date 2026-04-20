# Build derper from Tailscale source. No official image exists
# (see https://github.com/tailscale/tailscale/blob/main/cmd/derper/README.md:
# "You must build and update the cmd/derper binary yourself.").
#
# golang:1.26 matches tailscale.com go.mod `go 1.26.2` requirement as of
# April 2026. Tailscale bumps their Go toolchain periodically; if this
# build starts failing with "go.mod requires go >= X.Y.Z", bump the tag
# here and re-run.
FROM golang:1.26-alpine AS builder
# Docker caches this RUN layer, so `docker compose up -d --build` will NOT
# pick up a newer `@latest` on its own. To force a fresh pull of Tailscale's
# current main: `docker compose -p meshtest -f ../docker-compose.yml build
# --no-cache derper` (from tests/integration/). Cache stability is preferred
# for run-to-run test determinism; the escape hatch is manual.
RUN apk add --no-cache git ca-certificates \
 && go install tailscale.com/cmd/derper@latest

FROM alpine:3.19
# Intentionally runs as root. This image is for the sealed integration test
# harness only — it is not published, not production, and is torn down by
# run-tests.sh at exit. If this image ever gets reused outside that context,
# add a dedicated non-root user before shipping.
RUN apk add --no-cache ca-certificates
COPY --from=builder /go/bin/derper /usr/local/bin/derper
# Record the built version for later "which derper am I running?" diagnostics.
# Runs at image build time; output lands in `docker build` log and is cheap.
RUN /usr/local/bin/derper --version || true
EXPOSE 443 3478/udp
ENTRYPOINT ["/usr/local/bin/derper"]
