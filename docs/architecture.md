# Radix HFT Architecture

## Overview

Radix HFT is a production-grade DevOps infrastructure for a high-frequency trading (HFT) platform deployed on AWS EKS. The system is designed for sub-millisecond latency, zero-downtime deployments, and extreme scalability.

**Key Principles:**
- **Low-latency:** Order processing < 50ms P99
- **High-availability:** 99.99% uptime SLA
- **Elastic scalability:** Auto-scales from 100 to 100K orders/sec
- **GitOps-first:** Declarative infrastructure via ArgoCD
- **Observable:** Full observability with Prometheus/Grafana/Thanos

---

## System Architecture

```
┌─────────────────────────────────────────────────────────┐
│                       INTERNET                           │
└────────────────────────┬────────────────────────────────┘
                         │
                    ┌────▼────┐
                    │   ALB    │ (AWS Application Load Balancer)
                    │  + WAF   │
                    └────┬────┘
                         │
        ┌────────────────┼────────────────┐
        │                │                │
   ┌────▼─────┐   ┌─────▼────┐   ┌─────▼─────┐
   │ API GW   │   │ API GW    │   │  API GW   │
   │ (Pod)    │   │ (Pod)     │   │  (Pod)    │
   └────┬─────┘   └─────┬────┘   └─────┬─────┘
        │                │               │
        └────────────────┼───────────────┘
                         │
    ┌────────────────────┼────────────────────┐
    │                    │                    │
┌───▼──────┐   ┌────────▼────────┐   ┌──────▼────┐
│Order     │   │Market Data      │   │Risk       │
│Service   │   │Service (Rust)   │   │Engine     │
│(Go)      │   │                 │   │(Go)       │
└───┬──────┘   └────────┬────────┘   └──────┬────┘
    │                   │                   │
    └───────────────────┼───────────────────┘
                        │
        ┌───────────────┼───────────────┐
        │               │               │
   ┌────▼────┐   ┌─────▼──────┐   ┌───▼─────┐
   │ Kafka   │   │ Aurora     │   │ Redis   │
   │ (MSK)   │   │ PostgreSQL │   │ Cache   │
   └─────────┘   └────────────┘   └─────────┘
```

---

## Component Architecture

### Compute Layer (EKS)

**Kubernetes Cluster Configuration:**
- **Version:** 1.30 (latest stable)
- **Node Groups:**
  - `trading-critical`: t4g.2xlarge (arm64, reserved), optimized for low-latency order processing
  - `general-purpose`: t4g.xlarge (auto-scaling, spot), for background jobs
  - `data-intensive`: r6i.2xlarge (memory optimized), for analytics

**Pod Distribution:**
- **Order Service:** 3-20 replicas (HPA: CPU 70%, Memory 80%)
- **Market Data Service:** 3-12 replicas (KEDA: Kafka lag)
- **Risk Engine:** 2-8 replicas
- **API Gateway:** 3-10 replicas

**Network:**
- CNI: AWS VPC CNI (native ENI attachment)
- Service Mesh: Istio (mTLS enforced in `trading` namespace)
- Network Policy: Zero-trust (deny-all default, explicit allow rules)
- Ingress: AWS ALB with WAF, TLS termination

### Data Layer

**Aurora PostgreSQL (Primary Datastore)**
- **Version:** 16
- **Configuration:**
  - Multi-AZ deployment (3 AZs)
  - Read replicas: 2-4 (auto-scaling based on CPU)
  - Encryption: KMS key rotation every 90 days
  - Backup: 30-day retention, point-in-time recovery
  - Enhanced Monitoring: 1-second granularity

**Tables:**
- `orders` (orders by symbol, status, created_at)
- `executions` (execution history, audit log)
- `positions` (account holdings, real-time)
- `risk_limits` (per-account risk parameters)

**MSK Kafka (Event Stream)**
- **Version:** 3.7
- **Topics:**
  - `orders` (order submissions, 3 partitions, RF=3)
  - `executions` (fills & rejections, 6 partitions, RF=3)
  - `market-data` (tick data, 10 partitions, RF=2)
  - `risk-events` (risk check results, 3 partitions)
  - `audit-log` (compliance log, 1 partition, RF=3, retention: 365d)
- **Security:** IAM authentication, TLS in-transit, broker-side encryption
- **Retention:** 7 days (except audit: 365 days)

**ElastiCache Redis (Cache Layer)**
- **Version:** 7.1
- **Mode:** Cluster mode enabled (3 shards, 2 replicas per shard)
- **Use Cases:**
  - Session state (TTL: 1 hour)
  - Market data cache (OHLC, depth, TTL: 1 minute)
  - Rate limit counters (sliding window)
- **Security:** AUTH token (32-char random), TLS in-transit

---

## Service Tier

### Order Service (Go)

**Purpose:** Validates, persists, and routes orders to risk engine and Kafka.

**API Endpoints:**
- `POST /v1/orders` — Submit order
- `GET /v1/orders/{id}` — Retrieve order status
- `DELETE /v1/orders/{id}` — Cancel order
- `GET /health` — Health check

**Performance:**
- Throughput: 100K orders/sec (sustained)
- P99 Latency: < 50ms
- Error Rate: < 0.1%

**Deployment:**
- Container: distroless Go (1.22)
- Image Size: 12MB
- Resource Requests: 500m CPU, 512Mi RAM
- Resource Limits: 2000m CPU, 2Gi RAM

**Scaling:**
- HPA: CPU 70%, Memory 80%
- Min: 3, Max: 20 replicas
- Deployment Strategy: Argo Rollout (canary with analysis)

### Market Data Service (Rust)

**Purpose:** Ingests real-time market data from exchange feeds, enriches, and publishes.

**Features:**
- Multi-feed aggregation (NASDAQ, NYSE, CME)
- Order book reconstruction (depth snapshot + deltas)
- Latency tracking (feed → publish latency)

**Performance:**
- Feed lag: < 100ms P99
- Throughput: 1M ticks/sec
- Memory: < 8GB per instance

**Deployment:**
- Container: distroless Rust (1.78)
- Image Size: 18MB
- Resource Requests: 1000m CPU, 4Gi RAM
- Resource Limits: 4000m CPU, 16Gi RAM

**Scaling:**
- KEDA: Kafka consumer lag
- Min: 3, Max: 12 replicas
- Deployment Strategy: Argo Rollout (blue-green)

### Risk Engine (Go)

**Purpose:** Real-time risk validation before order execution.

**Risk Checks:**
- Position limits (per-symbol, per-account)
- Daily loss limits
- Concentration risk (VaR 99%)
- Margin requirements

**Performance:**
- Check time: < 5ms P99
- False positive rate: < 0.01%

**Resource Allocation:**
- Requests: 2000m CPU, 8Gi RAM
- Limits: 4000m CPU, 8Gi RAM
- Replicas: 2-8

**Scaling:**
- No auto-scaling (fixed to maintain latency SLO)
- Pod disruption budget: min 1 available

### API Gateway (Go)

**Purpose:** HTTP reverse proxy, rate limiting, request validation.

**Features:**
- TLS termination (ALB handles)
- Request routing to microservices
- Rate limiting: 10K req/sec per customer
- Request validation (JSON schema)
- CORS handling

**Performance:**
- Throughput: 100K req/sec
- Gateway latency: < 5ms P99

**Resource Allocation:**
- Requests: 500m CPU, 512Mi RAM
- Limits: 2000m CPU, 1Gi RAM
- Replicas: 3-10 (HPA)

---

## Observability Stack

### Prometheus (Metrics)

**Deployment:**
- EBS volume: 50GB with auto-scaling
- Retention: 30 days on disk, 365 days via Thanos
- Scrape interval: 30s (15s for critical services)

**Key Metric Families:**
- `http_request_duration_seconds` (histograms with buckets: 1,5,10,50,100ms)
- `http_requests_total` (counter by status)
- `db_connections_in_use` (gauge)
- `kafka_consumer_lag` (gauge)
- `order_latency_milliseconds` (histogram)
- `risk_check_duration_milliseconds` (histogram)

### Grafana (Dashboards)

**Key Dashboards:**
- **Trading Operations:** Order throughput, fill rates, P99 latency, error budget
- **Infrastructure:** Node CPU/memory, pod restarts, PVC usage
- **SLO Tracking:** Error budget burn rate, availability, latency SLO compliance

**Alert Rule Examples:**
- Error rate > 0.1% → Critical (P0)
- P99 latency > 50ms → Warning (P1)
- Aurora CPU > 80% → Warning (P1)
- Node disk < 10% → Critical (P0)

### Alertmanager (Alert Routing)

**Routing Policy:**
- **P0 (Critical + PagerDuty):** → PagerDuty + Slack #trading-p0
- **P1 (Warning):** → Slack #trading-alerts
- **P2 (Info):** → Email alerts@radix-hft.com
- **Watchdog:** → /dev/null (alive heartbeat)

**Escalation:**
- 30 min: PagerDuty escalates to on-call manager
- 1 hour: Escalates to VP Engineering

### Thanos (Long-term Storage)

**Setup:**
- S3 bucket: `radix-hft-metrics-archive`
- Storage class: INTELLIGENT_TIERING
- Retention: 365 days
- Downsampling: 30m after 30 days, 2h after 90 days

---

## Deployment Architecture

### GitOps (ArgoCD)

**Structure:**
```
radix-hft-devops/
├── helm/trading-platform/          # Helm chart
│   ├── values.yaml                 # base values
│   ├── values-prod.yaml            # prod overrides
│   ├── values-staging.yaml
│   └── templates/                  # Helm templates
├── argocd/applications/
│   └── trading-platform.yaml       # ArgoCD Application
└── kubernetes/                     # Raw K8s manifests
```

**Sync Policy:**
- Automated: Yes
- Auto-prune: Yes (delete resources not in Git)
- Self-heal: Yes (reconcile drift every 3 min)
- Retry: Up to 5 attempts with exponential backoff

### CI/CD Pipeline

**Triggers:**
- **PR:** Lint, security scan, unit tests
- **Push to main:** Build, push to GHCR, deploy to staging
- **Tag release:** Deploy to production (canary)

**Stages:**
1. **Lint:** YAML, Terraform, Helm
2. **Security:** Trivy (FS + images), GitLeaks, SBOM
3. **Build:** Docker buildx (cached, multi-arch)
4. **Test:** Integration tests, load test (k6)
5. **Deploy:** Helm upgrade + Argo Rollout (canary/blue-green)

### Progressive Deployment (Argo Rollouts)

**Prod Canary Strategy:**
1. Deploy 5% of replicas (canary)
2. Wait 5 min, run analysis (error rate, latency)
3. If pass, promote to 25%
4. Wait 10 min, run analysis
5. If pass, promote to 100%

**Staging Blue-Green:**
1. Deploy new version (green)
2. Run smoke tests
3. Switch traffic to green
4. Keep blue for rollback (30 min)

---

## Disaster Recovery

### Backup Strategy

**Database:**
- Automated snapshots: Hourly (24-hour retention) + daily (30-day retention)
- Point-in-time recovery: Enabled (7 days)
- Cross-region replica: Optional (for RTO < 1 min)

**Kafka:**
- S3 log archival: Enabled (all topics, retention: 365 days)
- Consumer group offsets: Persisted in broker (52 weeks)
- Replication factor: 3 (tolerates 2-broker failure)

**Configuration:**
- Terraform state: S3 backend with versioning + MFA delete
- Secrets: AWS Secrets Manager with audit logging

### RTO & RPO

| Component | RTO | RPO | Strategy |
|---|---|---|---|
| EKS cluster | 30 min | 0 min | Auto-replace nodes via ASG |
| Order Service | 2 min | 0 min | Multi-AZ, auto-scale |
| Aurora DB | 1 min | < 1 min | Multi-AZ failover + backups |
| Kafka | 5 min | < 1 min | 3-broker cluster, replication |
| Redis | 5 min | — | Cluster mode, snapshots |

---

## Security Architecture

### Network Security

**VPC Design:**
- Public subnets: NAT gateways (egress only)
- Private subnets: EC2 nodes, RDS, Kafka
- Database subnets: Aurora (no internet access)

**Network Policies:**
- Default: deny-all (namespace-level)
- Allow rules: order-service ↔ risk-engine, order-service ↔ kafka, etc.
- DNS: CoreDNS with query logging

### IAM & IRSA

**Service Account Annotations:**
- Order Service: `sts.amazonaws.com/role-arn: arn:aws:iam::ACCOUNT:role/order-service`
- Permissions: Secrets Manager (read), MSK (publish), RDS (connect)

**Instance Profile:**
- Node IAM role: EKS node minimal permissions
- AssumeRole: Only from EC2 service

### Secrets Management

**External Secrets Operator:**
- DB credentials: AWS Secrets Manager (rotate every 90 days)
- API keys: Synced to Kubernetes secrets
- Audit: CloudTrail logs all secret access

### Pod Security

**Pod Security Standards (Restricted):**
- No privileged containers
- No host namespace access
- Read-only root filesystem
- Non-root user (UID 65532)
- Capability drops: ALL
- SELinux context: restricted

---

## Cost Optimization

**Estimated Monthly Cost** (production):
- EKS control plane: $73
- EC2 instances: ~$2,000 (spot: ~50% savings)
- RDS Aurora: ~$1,500 (reserved: ~30% savings)
- Kafka (MSK): ~$1,200
- ElastiCache Redis: ~$400
- Data transfer: ~$800
- **Total:** ~$5,973/month

**Cost Reduction Levers:**
1. **Spot instances:** 50% savings (trading-general, data-intensive)
2. **Reserved instances:** 30-40% savings (trading-critical nodes)
3. **Graviton (ARM):** 20% cheaper than x86 (t4g instances)
4. **Data lifecycle:** Thanos downsampling, log rotation
5. **Consolidation:** Bin-pack pods with pod topology spread

---

## Operational Excellence

### Runbooks
- [Order Service Degradation](./runbooks/order-service-degradation.md)
- [Market Data Outage](./runbooks/market-data-outage.md)
- [Rollback Procedure](./runbooks/rollback.md)
- [Node Failure Recovery](./runbooks/node-failure.md)
- [Certificate Rotation](./runbooks/cert-rotation.md)

### Monitoring & Alerting
- **SLOs:** 99.99% availability, P99 latency < 50ms
- **Error Budget:** Monthly (10,368 seconds = ~2.88 hours)
- **Burn Rate Alerts:** 30x (P0), 10x (P1), 3x (P2)

### Change Management
- **Deployment Frequency:** Multiple times per day
- **Lead Time:** < 30 min (main → production)
- **MTTR:** < 15 min (P0), < 1 hour (P1)
- **Change Failure Rate:** < 15%

---

## Appendix: Key Technologies

| Layer | Technology | Version | Notes |
|---|---|---|---|
| Orchestration | Kubernetes (EKS) | 1.30 | AWS managed |
| Container Runtime | containerd | 1.7 | CRI-compatible |
| Service Mesh | Istio | 1.18 | mTLS, traffic management |
| Ingress | AWS ALB | — | ALB Ingress Controller |
| Secrets | AWS Secrets Manager | — | Rotated every 90 days |
| Database | Aurora PostgreSQL | 16 | Multi-AZ, auto-scaling |
| Cache | ElastiCache Redis | 7.1 | Cluster mode |
| Message Queue | MSK Kafka | 3.7 | 3-broker cluster |
| Metrics | Prometheus | 2.45 | 30-day retention |
| Visualization | Grafana | 10.0 | 15+ dashboards |
| Alerting | Alertmanager | — | Multi-channel routing |
| Long-term Storage | Thanos | 0.32 | S3 backend |
| Deployment | ArgoCD | 2.8 | GitOps |
| Progressive Delivery | Argo Rollouts | 1.6 | Canary/blue-green |
| Policy Enforcement | OPA/Gatekeeper | — | Admission controller |
| Load Testing | k6 | — | Performance benchmarking |

---

**Last Updated:** 2026-06-19  
**Architecture Version:** 2.0 (HFT-focused)
