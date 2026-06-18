# Changelog - Radix HFT DevOps Platform

All notable changes are documented here following [Conventional Commits](https://www.conventionalcommits.org/).

## [1.0.0] - 2026-06-01

### Features
- Full EKS 1.30 cluster with Karpenter autoscaler and multi-AZ node groups.
- GitOps delivery via ArgoCD ApplicationSet (dev → staging → prod).
- Canary deployments with Argo Rollouts + Istio traffic splitting.
- Prometheus/Grafana observability stack with SLO-based alerting.
- External Secrets Operator integration with AWS Secrets Manager.
- OPA Gatekeeper admission control with 6 policy constraints.
- Falco runtime security with eBPF driver.
- Multi-stage distroless Dockerfiles for all 4 services.
- k6 load test simulating realistic HFT traffic (orders + WebSocket).
- Full Terraform IaC: VPC, EKS, Aurora, ElastiCache, MSK, IAM.

### Infrastructure
- Aurora PostgreSQL 16.2 with auto-scaling read replicas.
- ElastiCache Redis 7.1 cluster mode (3 shards, 2 replicas each).
- MSK Kafka 3.7.0 with IAM authentication and TLS encryption.
- Thanos long-term metrics storage (S3 + Glacier tiering).

### CI/CD
- 4-stage GitHub Actions pipeline: lint → security → test → build.
- Trivy vulnerability scanning with SARIF upload to GitHub Security.
- cosign image signing for supply chain integrity.
- Nightly drift detection and CIS benchmark scans.
- Semantic versioning with git-cliff changelog generation.

### Security
- Zero-trust networking: default-deny NetworkPolicies + Istio mTLS.
- IMDSv2 enforced on all EC2 instances.
- KMS encryption at rest for EKS secrets, Aurora, Redis, MSK, S3.
- Approved registry allowlist enforced at admission.
- SBOM generated per build (SPDX JSON format).
