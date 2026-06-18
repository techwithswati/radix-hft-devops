# ⚡ Radix HFT DevOps Platform

<div align="center">

![Platform Status](https://img.shields.io/badge/Platform-Production%20Ready-brightgreen?style=for-the-badge)
![Kubernetes](https://img.shields.io/badge/Kubernetes-1.30-326CE5?style=for-the-badge&logo=kubernetes)
![Terraform](https://img.shields.io/badge/Terraform-1.9-7B42BC?style=for-the-badge&logo=terraform)
![ArgoCD](https://img.shields.io/badge/ArgoCD-GitOps-EF7B4D?style=for-the-badge&logo=argo)
![AWS](https://img.shields.io/badge/AWS-EKS-FF9900?style=for-the-badge&logo=amazonaws)

**Enterprise-grade DevOps infrastructure for a High-Frequency Trading platform built on AWS EKS.**
Designed to support sub-millisecond latency workloads with zero-downtime deployments, full observability, and GitOps-driven delivery.

[Architecture](#-architecture) • [Tech Stack](#-tech-stack) • [Quick Start](#-quick-start) • [CI/CD](#-cicd-pipeline) • [Monitoring](#-observability-stack) • [Security](#-security)

</div>

---

## 📐 Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          AWS Cloud (us-east-1)                          │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                    VPC (10.0.0.0/16)                            │   │
│  │                                                                  │   │
│  │  ┌──────────────────────┐    ┌──────────────────────────────┐  │   │
│  │  │   Public Subnets     │    │      Private Subnets         │  │   │
│  │  │  ┌──────────────┐    │    │  ┌───────────────────────┐   │  │   │
│  │  │  │ NAT Gateway  │    │    │  │   EKS Node Groups     │   │  │   │
│  │  │  │ ALB Ingress  │    │    │  │  ┌─────────────────┐  │   │  │   │
│  │  │  └──────────────┘    │    │  │  │ order-service   │  │   │  │   │
│  │  └──────────────────────┘    │  │  │ market-data-svc │  │   │  │   │
│  │                               │  │  │ risk-engine     │  │   │  │   │
│  │  ┌──────────────────────┐    │  │  │ api-gateway     │  │   │  │   │
│  │  │   Data Tier          │    │  │  └─────────────────┘  │   │  │   │
│  │  │  ┌──────────────┐    │    │  │                       │   │  │   │
│  │  │  │  Aurora PG   │    │    │  │  ArgoCD | Prometheus  │   │  │   │
│  │  │  │  ElastiCache │    │    │  │  Grafana | Loki       │   │  │   │
│  │  │  │  MSK Kafka   │    │    │  └───────────────────────┘   │  │   │
│  │  │  └──────────────┘    │    └──────────────────────────────┘  │   │
│  │  └──────────────────────┘                                       │   │
│  └─────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
         ↑ GitOps                      ↑ Observability
    GitHub → ArgoCD              Prometheus → Grafana
```

## 🛠 Tech Stack

| Layer | Technology | Purpose |
|---|---|---|
| **Cloud** | AWS (EKS, Aurora, ElastiCache, MSK) | Infrastructure |
| **IaC** | Terraform 1.9 | Infrastructure provisioning |
| **Container Orchestration** | Kubernetes 1.30 | Workload management |
| **Package Management** | Helm 3 | Kubernetes app packaging |
| **GitOps** | ArgoCD | Continuous delivery |
| **CI/CD** | Github Actions | Build & test automation |
| **Service Mesh** | Istio | mTLS, traffic management |
| **Observability** | Prometheus + Grafana + Loki | Metrics, dashboards, logs |
| **Security** | Trivy + OPA + Falco | Container & policy scanning |
| **Load Testing** | k6 | Performance validation |
| **Secrets** | AWS Secrets Manager + ESO | Secret management |
| **Autoscaling** | Karpenter + KEDA | Node and pod autoscaling |

## 🚀 Quick Start

### Prerequisites

```bash
aws --version          # >= 2.15
terraform --version    # >= 1.9
kubectl version        # >= 1.30
helm version           # >= 3.14
argocd version         # >= 2.10
```

### 1. Clone & Configure

```bash
git clone https://github.com/techwithswati/radix-hft-devops.git
cd radix-hft-devops
aws configure --profile radix-hft
export AWS_PROFILE=radix-hft
```

### 2. Bootstrap Infrastructure

```bash
cd terraform/environments/prod
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

### 3. Configure kubectl

```bash
aws eks update-kubeconfig --region us-east-1 --name radix-hft-prod
```

### 4. Install Core Platform

```bash
chmod +x scripts/bootstrap.sh
./scripts/bootstrap.sh --env prod
```

### 5. Deploy via ArgoCD

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
argocd login localhost:8080
argocd app sync --all
```

## 🔄 CI/CD Pipeline

```
Developer Push → GitHub PR
       │
       ▼
  GitHub Actions
  ┌─────────────────────────────────┐
  │  1. Lint (hadolint, yamllint)   │
  │  2. Security Scan (Trivy, SAST) │
  │  3. Unit Tests                  │
  │  4. Build & Push Docker Images  │
  │  5. Helm Chart Validation       │
  │  6. OPA Policy Check            │
  │  7. Load Test (k6 smoke)        │
  └─────────────────────────────────┘
       │
       ▼  (on merge to main)
  ArgoCD GitOps Sync
  ┌─────────────────────────────────┐
  │  Dev  → auto-sync               │
  │  Staging → auto-sync + tests    │
  │  Prod  → manual gate + canary   │
  └─────────────────────────────────┘
```

### Deployment Strategy

| Environment | Strategy | Rollback Time |
|---|---|---|
| `dev` | Rolling update | < 30s |
| `staging` | Blue/Green | < 10s |
| `prod` | Canary (5% → 25% → 100%) | < 5s |

## 📊 Observability Stack

### Key SLOs

```yaml
order_service:
  availability: 99.99%
  latency_p99: 50ms
  latency_p999: 100ms

market_data_service:
  availability: 99.999%
  latency_p99: 5ms
  throughput: 1_000_000 msgs/sec
```

### Alerts

| Alert | Severity | Threshold |
|---|---|---|
| Order service error rate | P0 | > 0.1% for 1m |
| Market data lag | P0 | > 100ms |
| Node CPU saturation | P1 | > 85% for 5m |
| Pod OOMKilled | P1 | Any occurrence |
| Certificate expiry | P2 | < 14 days |

## 🔐 Security

```
1. Network:      Cilium NetworkPolicies (default-deny).
2. Workload:     Pod Security Standards (restricted).
3. Runtime:      Falco rules for anomaly detection.
4. Supply Chain: Trivy + cosign image signing.
5. Secrets:      AWS Secrets Manager via External Secrets Operator.
6. Policy:       OPA Gatekeeper for admission control.
7. mTLS:         Istio service-to-service encryption.
```

### Compliance
- ✅ SOC 2 Type II controls.
- ✅ PCI DSS network segmentation.
- ✅ CIS Kubernetes Benchmark.
- ✅ NIST 800-190 container security.

## Repository Structure

```
radix-hft-devops/
├── .github/workflows/   # CI/CD pipelines
├── terraform/           # IaC (AWS) - modules + environments
├── kubernetes/          # Raw K8s manifests
├── helm/trading-platform/  # Helm chart
├── monitoring/          # Prometheus rules & Grafana dashboards
├── argocd/              # GitOps application definitions
├── docker/              # Service Dockerfiles
├── k6-tests/            # Load test scenarios
├── scripts/             # Automation scripts
├── policies/            # OPA Rego policies
└── docs/                # Architecture docs & runbooks
```

## 🏗 Infrastructure Sizing (Production)

| Node Group | Instance | Count | Purpose |
|---|---|---|---|
| `trading-critical` | c6i.4xlarge | 6 | Order/risk services |
| `market-data` | r6i.2xlarge | 4 | High-memory data feed |
| `monitoring` | m6i.2xlarge | 2 | Prometheus, Grafana |
| `system` | m6i.xlarge | 3 | ArgoCD, Istio, etc. |

## 📖 Runbooks

| Scenario | Runbook |
|---|---|
| Order service degradation | [docs/runbooks/order-service-degradation.md](docs/runbooks/order-service-degradation.md) |
| Market data feed outage | [docs/runbooks/market-data-outage.md](docs/runbooks/market-data-outage.md) |
| Node failure | [docs/runbooks/node-failure.md](docs/runbooks/node-failure.md) |
| Rollback procedure | [docs/runbooks/rollback.md](docs/runbooks/rollback.md) |
| Certificate rotation | [docs/runbooks/cert-rotation.md](docs/runbooks/cert-rotation.md) |

## 🤝 Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development workflow, branch strategy, and commit conventions.

## 📄 License

2026 Swati. Shared for portfolio purposes - not open source.
Interested in working together? Reach out before using any part of this project.
See [LICENSE](LICENSE) for full terms.

---

<div align="center">
Sub-millisecond latency • Zero-downtime deployments
</div>
