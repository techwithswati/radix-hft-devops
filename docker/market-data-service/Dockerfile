# syntax=docker/dockerfile:1.9
##############################################################
# Radix HFT — Market Data Service (Rust)
# 1M+ msg/s feed aggregator: multi-exchange WebSocket + REST
##############################################################

# ── Stage 1: Dependency cache (cargo-chef) ────────────────
FROM rust:1.78-alpine3.20 AS chef
RUN apk add --no-cache musl-dev=1.2.5_git20240514-r0 && cargo install cargo-chef --locked
WORKDIR /app

FROM chef AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

# ── Stage 2: Build ─────────────────────────────────────────
FROM chef AS builder
ARG BUILD_DATE
ARG GIT_COMMIT
ARG VERSION

RUN apk add --no-cache musl-dev=1.2.5_git20240514-r0 openssl-dev=3.2.2-r0 pkgconfig=2.3.0-r0

COPY --from=planner /app/recipe.json recipe.json
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/app/target \
    cargo chef cook --release --recipe-path recipe.json

COPY . .
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/app/target \
    RUSTFLAGS="-C target-cpu=native -C opt-level=3" \
    cargo build --release --bin market-data-service && \
    cp target/release/market-data-service /bin/market-data-service && \
    strip /bin/market-data-service

# ── Stage 3: Runtime (distroless) ─────────────────────────
FROM gcr.io/distroless/static-debian12:nonroot AS runtime

LABEL org.opencontainers.image.title="Radix HFT Market Data Service" \
      org.opencontainers.image.description="High-throughput market data feed aggregation service (Rust)" \
      org.opencontainers.image.vendor="Radix HFT" \
      org.opencontainers.image.licenses="LicenseRef-Portfolio" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${GIT_COMMIT}" \
      org.opencontainers.image.version="${VERSION}"

COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /bin/market-data-service /bin/market-data-service

USER 65532:65532

# HTTP/REST
EXPOSE 8081

# WebSocket
EXPOSE 8082

# Prometheus metrics
EXPOSE 9091

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD ["/bin/market-data-service", "--health-check"]

ENTRYPOINT ["/bin/market-data-service"]
CMD ["--config", "/etc/market-data/config.yaml"]
