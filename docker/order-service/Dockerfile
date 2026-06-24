# syntax=docker/dockerfile:1.9
##############################################################
# Radix HFT - Order Service
# Multi-stage build: Go 1.22 binary, distroless runtime
# Target: < 10ms cold start, < 5MB image
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

# Build dependencies (static binary, no CGO)
RUN apk add --no-cache git ca-certificates tzdata

WORKDIR /app

# Copy modules from cache stage
COPY --from=modules /go/pkg/mod /go/pkg/mod
COPY go.mod go.sum ./
COPY . .

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 \
    GOOS=linux \
    GOARCH=amd64 \
    GOFLAGS="-trimpath" \
    go build \
      -ldflags="-s -w \
        -X main.Version=${VERSION} \
        -X main.GitCommit=${GIT_COMMIT} \
        -X main.BuildDate=${BUILD_DATE} \
      -o /bin/order-service \
      ./cmd/order-service

# Verify binary
RUN /bin/order-service --version

# ── Stage 3: Security scan ─────────────────────────────────
FROM aquasec/trivy:latest AS trivy-scan
COPY --from=builder /bin/order-service /bin/order-service
RUN trivy rootfs --no-progress --exit-code 0 --severity HIGH,CRITICAL /

# ── Stage 4: Runtime (distroless) ─────────────────────────
FROM gcr.io/distroless/static-debian12:nonroot AS runtime

# OCI image annotations
LABEL org.opencontainers.image.title="Radix HFT Order Service" \
      org.opencontainers.image.description="High-frequency trading order management service" \
      org.opencontainers.image.vendor="Radix HFT" \
      org.opencontainers.image.url="https://github.com/techwithswati/radix-hft-devops" \
      org.opencontainers.image.source="https://github.com/techwithswati/radix-hft-devops" \
      org.opencontainers.image.licenses="LicenseRef-Portfolio" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${GIT_COMMIT}" \
      org.opencontainers.image.version="${VERSION}"

# Copy CA certificates for TLS
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /usr/share/zoneinfo /usr/share/zoneinfo

# Copy binary
COPY --from=builder /bin/order-service /bin/order-service

# Non-root user (65532 = nonroot in distroless)
USER 65532:65532

# Expose ports
# HTTP/REST
EXPOSE 8080

# gRPC
EXPOSE 9000

# Prometheus metrics
EXPOSE 9090

# Health check (distroless doesn't have shell, use native)
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD ["/bin/order-service", "--health-check"]

ENTRYPOINT ["/bin/order-service"]
CMD ["--config", "/etc/order-service/config.yaml"]
