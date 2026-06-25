# syntax=docker/dockerfile:1.9
##############################################################
# Radix HFT — Risk Engine
# Sub-5ms VaR calculation, position limits, pre-trade checks
##############################################################

# ── Stage 1: Module cache ──────────────────────────────────
FROM golang:1.22-alpine3.20 AS modules
WORKDIR /app
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download -x

# ── Stage 2: Build ─────────────────────────────────────────
FROM golang:1.22-alpine3.20 AS builder
ARG BUILD_DATE
ARG GIT_COMMIT
ARG VERSION

RUN apk add --no-cache git=2.42.0-r0 ca-certificates=20240705-r0

WORKDIR /app
COPY --from=modules /go/pkg/mod /go/pkg/mod
COPY go.mod go.sum ./
COPY . .

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOFLAGS="-trimpath" \
    go build \
      -ldflags="-s -w \
        -X main.Version=${VERSION} \
        -X main.GitCommit=${GIT_COMMIT} \
        -X main.BuildDate=${BUILD_DATE}" \
      -o /bin/risk-engine \
      ./cmd/risk-engine

RUN /bin/risk-engine --version

# ── Stage 3: Security scan ─────────────────────────────────
FROM aquasec/trivy:0.50.0 AS trivy-scan
COPY --from=builder /bin/risk-engine /bin/risk-engine
RUN trivy rootfs --no-progress --exit-code 0 --severity HIGH,CRITICAL /

# ── Stage 4: Runtime (distroless) ─────────────────────────
FROM gcr.io/distroless/static-debian12:nonroot AS runtime

LABEL org.opencontainers.image.title="Radix HFT Risk Engine" \
      org.opencontainers.image.description="Pre-trade risk checks: position limits, VaR, kill switch" \
      org.opencontainers.image.vendor="Radix HFT" \
      org.opencontainers.image.licenses="LicenseRef-Portfolio" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${GIT_COMMIT}" \
      org.opencontainers.image.version="${VERSION}"

COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /bin/risk-engine /bin/risk-engine

USER 65532:65532

# HTTP/REST
EXPOSE 8083

# gRPC
EXPOSE 9003

# Prometheus metrics
EXPOSE 9093

HEALTHCHECK --interval=10s --timeout=2s --start-period=5s --retries=3 \
  CMD ["/bin/risk-engine", "--health-check"]

ENTRYPOINT ["/bin/risk-engine"]
CMD ["--config", "/etc/risk-engine/config.yaml"]
