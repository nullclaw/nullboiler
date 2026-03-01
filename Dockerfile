# syntax=docker/dockerfile:1

# -- Stage 1: Build ----------------------------------------------------------
FROM alpine:3.23 AS builder

RUN apk add --no-cache zig musl-dev

WORKDIR /app
COPY build.zig build.zig.zon ./
COPY src/ src/

ARG TARGETARCH
RUN set -eu; \
    arch="${TARGETARCH:-}"; \
    if [ -z "${arch}" ]; then \
      case "$(uname -m)" in \
        x86_64) arch="amd64" ;; \
        aarch64|arm64) arch="arm64" ;; \
        *) echo "Unsupported host arch: $(uname -m)" >&2; exit 1 ;; \
      esac; \
    fi; \
    case "${arch}" in \
      amd64) zig_target="x86_64-linux-musl" ;; \
      arm64) zig_target="aarch64-linux-musl" ;; \
      *) echo "Unsupported TARGETARCH: ${arch}" >&2; exit 1 ;; \
    esac; \
    zig build -Dtarget="${zig_target}" -Doptimize=ReleaseSmall

# -- Stage 2: Config Prep ----------------------------------------------------
FROM busybox:1.37 AS config

RUN mkdir -p /nullboiler-data/.nullboiler /nullboiler-data/workspace

RUN cat > /nullboiler-data/.nullboiler/config.json << 'EOF'
{
  "gateway": {
    "port": 3000,
    "host": "::",
    "allow_public_bind": true
  }
}
EOF

# Default runtime runs as non-root (uid/gid 65534).
# Keep writable ownership for HOME/workspace in safe mode.
RUN chown -R 65534:65534 /nullboiler-data

# -- Stage 3: Runtime Base (shared) ------------------------------------------
FROM alpine:3.23 AS release-base

LABEL org.opencontainers.image.source=https://github.com/nullboiler/nullboiler

RUN apk add --no-cache ca-certificates curl tzdata

COPY --from=builder /app/zig-out/bin/nullboiler /usr/local/bin/nullboiler
COPY --from=config /nullboiler-data /nullboiler-data

ENV NULLBOILER_WORKSPACE=/nullboiler-data/workspace
ENV HOME=/nullboiler-data
ENV NULLBOILER_GATEWAY_PORT=3000

WORKDIR /nullboiler-data
EXPOSE 3000
ENTRYPOINT ["nullboiler"]
CMD ["gateway", "--port", "3000", "--host", "::"]

# Optional autonomous mode (explicit opt-in):
#   docker build --target release-root -t nullboiler:root .
FROM release-base AS release-root
USER 0:0

# Safe default image (used when no --target is provided)
FROM release-base AS release
USER 65534:65534
