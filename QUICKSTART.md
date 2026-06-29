# Quick Start Guide — Radix HFT DevOps

Get up and running with Radix HFT in 10 minutes.

---

## Prerequisites

Install required tools:

```bash
# macOS (using Homebrew)
brew install kubectl helm aws-cli docker git

# Linux (Ubuntu/Debian)
sudo apt-get install -y kubectl helm awscli docker.io git

# Docker Desktop (for local testing)
# Download from: https://www.docker.com/products/docker-desktop
```

**Verify installation:**
```bash
kubectl version --client
helm version
aws --version
docker --version
```

---

## Setup AWS Access

```bash
# Configure AWS credentials
aws configure
# Enter: Access Key ID, Secret Access Key, Region (us-east-1), Output format (json)

# Verify access
aws sts get-caller-identity
# Should show your AWS account details

# Update kubeconfig
aws eks update-kubeconfig \
  --name radix-hft-prod \
  --region us-east-1

# Test cluster access
kubectl cluster-info
kubectl get nodes
```

---

## Deploy to Staging (5 min)

```bash
# 1. Clone repository
git clone https://github.com/radix-hft/radix-hft-devops.git
cd radix-hft-devops

# 2. Install pre-commit hooks (optional but recommended)
pip install pre-commit
pre-commit install

# 3. Deploy to staging
kubectl config set-context --current --namespace=trading

helm upgrade --install trading-platform helm/trading-platform/ \
  -f helm/trading-platform/values-staging.yaml \
  --wait --timeout 10m

# 4. Verify deployment
kubectl get pods -n trading
kubectl get services -n trading

# 5. Run smoke tests
bash scripts/smoke-tests.sh
```

**Expected output:**
```
✓ Connected to Kubernetes cluster
✓ Namespace trading exists
✓ Deployment order-service is ready
✓ Deployment market-data-service is ready
✓ All tests passed
```

---

## Development Workflow

### Make a Change

```bash
# 1. Create feature branch
git checkout -b feature/my-feature

# 2. Make code changes
# Edit files in:
# - docker/*/Dockerfile (service code)
# - helm/trading-platform/templates/ (K8s manifests)
# - scripts/ (operational scripts)

# 3. Run pre-commit checks (auto-fixes style issues)
pre-commit run --all-files

# 4. Commit changes (conventional commits)
git commit -m "feat(order-service): add order validation"
# Message format: type(scope): description
# Types: feat, fix, doc, test, refactor, perf, ci, ops, infra, security

# 5. Push to GitHub
git push origin feature/my-feature
```

### Create Pull Request

```bash
# Open in browser or use gh CLI
gh pr create --title "Add order validation" \
  --body "Validates orders before submission"

# PR template will auto-populate with:
# - Description
# - Testing checklist
# - Deployment notes
# - Rollback plan

# CI will automatically run:
# ✓ Lint (YAML, Terraform, Docker)
# ✓ Security scan (Trivy, GitLeaks)
# ✓ Build Docker images
# ✓ Integration tests
```

### Review & Merge

```bash
# Once CI passes and reviewers approve:
git merge feature/my-feature

# Or merge via GitHub UI (Squash and merge recommended)
```

---

## Local Testing

### Test Order Service Locally

```bash
# 1. Build Docker image
docker build -t order-service:local docker/order-service/

# 2. Start dependencies (optional)
docker-compose up -d postgres kafka redis

# 3. Run service
docker run -e DB_HOST=localhost -e KAFKA_BROKERS=localhost:9092 \
  -p 8080:8080 order-service:local

# 4. Test endpoint
curl -X POST http://localhost:8080/v1/orders \
  -H "Content-Type: application/json" \
  -d '{"symbol":"AAPL","quantity":100,"price":150.0}'

# Expected: 201 Created with order_id
```

### Run Tests Locally

```bash
# Smoke tests
bash scripts/smoke-tests.sh

# Integration tests (requires staging K8s access)
bash scripts/integration-tests.sh

# Load test with k6
k6 run k6-tests/smoke-test.js

# Or with custom parameters
k6 run k6-tests/trading-load-test.js \
  --vus 10 --duration 1m \
  -e API_BASE_URL=http://api.staging.radix-hft.com
```

---

## Debugging

### View Pod Logs

```bash
# Latest logs
kubectl logs -n trading deployment/order-service --tail=50

# Follow live logs
kubectl logs -n trading -f deployment/order-service

# Logs from all pods with label
kubectl logs -n trading -l app=order-service --all-containers=true -f
```

### Shell into Pod

```bash
# Interactive shell
kubectl exec -it deployment/order-service -n trading -- /bin/bash

# Or quick command
kubectl exec -it deployment/order-service -n trading -- \
  curl http://localhost:8080/health
```

### Check Metrics

```bash
# Port-forward to Prometheus
kubectl port-forward -n monitoring svc/prometheus-server 9090:80 &

# Open browser to localhost:9090
# Query examples:
# - rate(http_requests_total{service="order-service"}[5m])
# - histogram_quantile(0.99, http_request_duration_seconds_bucket)
```

### View Events

```bash
# Recent cluster events
kubectl get events -n trading --sort-by='.lastTimestamp' | tail -20

# Watch for changes
kubectl get events -n trading -w
```

---

## Common Tasks

### Scale Service Up/Down

```bash
# Manual scale
kubectl scale deployment order-service -n trading --replicas=5

# Or edit HPA
kubectl edit hpa order-service -n trading
# Change minReplicas and maxReplicas

# Check HPA status
kubectl get hpa -n trading -o wide
```

### Update Configuration

```bash
# Edit ConfigMap
kubectl edit configmap order-service-config -n trading

# Restart pods to pick up changes
kubectl rollout restart deployment/order-service -n trading

# Watch rollout
kubectl rollout status deployment/order-service -n trading
```

### Check Service Status

```bash
# Quick status
kubectl get all -n trading

# Detailed status
kubectl describe deployment order-service -n trading
kubectl describe service order-service -n trading

# Check ingress
kubectl get ingress -n trading -o wide
```

### Rollback Deployment

```bash
# See deployment history
kubectl rollout history deployment/order-service -n trading

# Rollback to previous revision
kubectl rollout undo deployment/order-service -n trading

# Rollback to specific revision
kubectl rollout undo deployment/order-service -n trading --to-revision=3

# Or use Helm
helm rollback trading-platform
helm history trading-platform -n trading
```

---

## Troubleshooting

### Pods Not Starting?

```bash
# Check pod status
kubectl describe pod <pod-name> -n trading
# Look for: ImagePullBackOff, CrashLoopBackOff, Pending

# For ImagePullBackOff:
# - Check image exists: docker pull <image>
# - Check image registry credentials: kubectl get secret -n trading

# For CrashLoopBackOff:
# - Check logs: kubectl logs <pod-name> -n trading
# - Check resource limits: kubectl top pods -n trading
```

### Requests Failing?

```bash
# Check service connectivity
kubectl run -it debug --image=curlimages/curl --restart=Never -n trading -- \
  curl http://order-service:8080/health

# Check DNS
kubectl run -it debug --image=busybox --restart=Never -n trading -- \
  nslookup order-service

# Check network policies
kubectl get networkpolicies -n trading
```

### Performance Issues?

```bash
# Check resource usage
kubectl top pods -n trading
kubectl top nodes

# Check for throttling
kubectl get --raw /apis/metrics.k8s.io/v1beta1/namespaces/trading/pods | \
  jq '.items[] | {name: .metadata.name, cpu: .usage.cpu, memory: .usage.memory}'

# Check latency in metrics (Prometheus)
# Query: histogram_quantile(0.99, http_request_duration_seconds_bucket)
```

---

## Environment Variables

Set for local development:

```bash
export AWS_REGION=us-east-1
export KUBECONFIG=~/.kube/config
export DOCKER_REGISTRY=ghcr.io
export IMAGE_TAG=dev
export API_BASE_URL=http://api.staging.radix-hft.com
```

---

## Useful Aliases

Add to `~/.bashrc` or `~/.zshrc`:

```bash
alias k=kubectl
alias h=helm
alias kgp='kubectl get pods -n trading'
alias kd='kubectl describe'
alias kl='kubectl logs -n trading'
alias ke='kubectl exec -it'
alias krr='kubectl rollout restart deployment'
alias krs='kubectl rollout status deployment'

# Kubernetes context shortcuts
alias kc-staging='kubectl config set-context --current --namespace=trading && echo "Switched to trading namespace"'
```

---

## Documentation Links

- **Architecture:** [docs/architecture.md](./docs/architecture.md)
- **Runbooks:** [docs/runbooks/](./docs/runbooks/)
- **CI/CD:** [.github/workflows/](https://github.com/radix-hft/radix-hft-devops/tree/main/.github/workflows)
- **Helm Chart:** [helm/trading-platform/](./helm/trading-platform/README.md)
- **Terraform:** [terraform/README.md](./terraform/README.md)

---

## Getting Help

1. **Check the docs:** [docs/](./docs/)
2. **Search issues:** https://github.com/radix-hft/radix-hft-devops/issues
3. **Ask in Slack:** #radix-devops
4. **Page on-call:** In emergencies, use PagerDuty (incident-commander)

---

## Next Steps

- [ ] Set up AWS credentials
- [ ] Deploy to staging
- [ ] Run smoke tests
- [ ] Create your first feature branch
- [ ] Read architecture docs
- [ ] Review runbooks for your service

---

**Happy shipping! 🚀**

Last updated: 2026-06-19
