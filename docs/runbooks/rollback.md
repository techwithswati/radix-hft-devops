# Runbook: Deployment Rollback

**Purpose:** Quickly roll back a failed deployment to last known-good state  
**Severity:** P0-P1 | **RTO:** < 5 min | **RPO:** 0 min

---

## When to Rollback

**Immediate Rollback Triggers:**
- ✋ Error rate > 1% (sustained > 2 min)
- ✋ P99 latency > 200ms (sustained > 2 min)
- ✋ Service unavailable (503/504 > 5%)
- ✋ Data corruption detected
- ✋ Deployment failed (pod crash, image pull error)

**NOT a Rollback Trigger:**
- Minor latency increase (5-10ms)
- Low error rate < 0.5% (transient)
- Flaky tests in staging

---

## Before You Rollback

### **Assess Impact**

```bash
# Is it really broken?
kubectl get pods -n trading -l app=order-service

# What's the error?
kubectl logs -n trading -l app=order-service --tail=50 | grep -i error

# When did it start?
kubectl get events -n trading --sort-by='.lastTimestamp' | grep order-service | tail -20
```

### **Notify Stakeholders**
```bash
# Slack
@incident-commander Rolling back order-service to [VERSION]
Reason: [Brief issue description]
ETA: 3-5 minutes
```

---

## Rollback Strategies

### **Strategy 1: Argo Rollout Automatic Rollback** ⭐ FASTEST

If using Argo Rollout with analysis templates:

```bash
# Check if rollout is in DEGRADED state
kubectl get rollout order-service -n trading

# Rollout should auto-rollback if analysis fails
# Monitor progress
kubectl get rollout order-service -n trading -w

# View rollout history
kubectl describe rollout order-service -n trading | grep -A 20 "Stable Revision"
```

**Advantages:** Automatic, fast (~30-60s)  
**Disadvantages:** Depends on analysis templates working correctly

---

### **Strategy 2: Helm Rollback** ⭐ RECOMMENDED

Rollback the last Helm release:

```bash
# List releases
helm list -n trading

# Show release history
helm history trading-platform -n trading | head -10

# Example output:
# REVISION  UPDATED       STATUS     CHART
# 2         Jun 19 14:24  DEPLOYED   trading-platform-1.5.0
# 1         Jun 19 10:15  SUPERSEDED trading-platform-1.4.9

# Rollback to previous release (revision 1)
helm rollback trading-platform 1 -n trading

# Or rollback to specific revision
helm rollback trading-platform 1 -n trading

# Wait for rollout
kubectl rollout status deployment/order-service -n trading --timeout=5m
```

**Advantages:** Simple, one command, idempotent  
**Disadvantages:** Requires Helm chart management

---

### **Strategy 3: Kubernetes Rollback** (Native)

```bash
# View deployment history
kubectl rollout history deployment/order-service -n trading

# Example output:
# REVISION  CHANGE-CAUSE
# 2         kubectl set image deployment/order-service...
# 1         kubectl apply -f order-service.yaml

# Rollback to previous revision
kubectl rollout undo deployment/order-service -n trading

# Or rollback to specific revision
kubectl rollout undo deployment/order-service -n trading --to-revision=1

# Monitor progress
kubectl rollout status deployment/order-service -n trading --timeout=5m

# View current image
kubectl get deployment order-service -n trading -o jsonpath='{.spec.template.spec.containers[0].image}'
```

**Advantages:** Native Kubernetes, works everywhere  
**Disadvantages:** Limited rollout control, doesn't rollback config changes

---

### **Strategy 4: Manual Image Rollback** (Emergency Only)

```bash
# Find previous image tag
kubectl get deployment order-service -n trading -o jsonpath='{.spec.template.spec.containers[0].image}'
# Output: ghcr.io/radix-hft/order-service:abc1234

# Look up previous tag in git history
git log --oneline --all -- docker/order-service/ | head -5
# abc1234 fix: order-service timeout handling
# xyz7890 feat: add market data caching
# OLD_TAG would be xyz7890

# Manually set image to previous version
kubectl set image deployment/order-service -n trading \
  order-service=ghcr.io/radix-hft/order-service:xyz7890 \
  --record

# Wait for rollout
kubectl rollout status deployment/order-service -n trading --timeout=5m
```

**Advantages:** Fine-grained control  
**Disadvantages:** Error-prone, hard to find correct tag

---

### **Strategy 5: ArgoCD Sync Rollback**

If using ArgoCD for GitOps:

```bash
# Check ArgoCD app status
kubectl get application trading-platform -n argocd

# Revert Git commit
git revert HEAD
git push origin main

# ArgoCD will auto-sync (if auto-sync enabled)
# Or manually sync
argocd app sync trading-platform --server localhost:8080

# Monitor
argocd app wait trading-platform --operation --timeout 300s
```

**Advantages:** Declarative, auditable (Git history)  
**Disadvantages:** Slower (requires git push), if ArgoCD is down this fails

---

## Step-by-Step Rollback Procedure

### **For Most Incidents: Use Strategy 2 (Helm)**

```bash
#!/bin/bash
set -euo pipefail

NAMESPACE="trading"
RELEASE="trading-platform"

echo "🔄 Rolling back $RELEASE in $NAMESPACE..."

# Step 1: Verify we're in the right cluster
echo "✓ Connected to cluster: $(kubectl config current-context)"

# Step 2: Check current status
echo "Current deployment:"
helm status $RELEASE -n $NAMESPACE

# Step 3: Show what we're rolling back
echo "Previous releases:"
helm history $RELEASE -n $NAMESPACE | head -5

# Step 4: Get previous revision
PREVIOUS_REVISION=$(helm history $RELEASE -n $NAMESPACE | tail -2 | head -1 | awk '{print $1}')
echo "Rolling back to revision: $PREVIOUS_REVISION"

# Step 5: Perform rollback
echo "Executing rollback..."
helm rollback $RELEASE $PREVIOUS_REVISION -n $NAMESPACE --wait --timeout 5m

# Step 6: Verify rollback
echo "Waiting for deployment to stabilize..."
kubectl rollout status deployment/order-service -n $NAMESPACE --timeout=5m
kubectl rollout status deployment/market-data-service -n $NAMESPACE --timeout=5m
kubectl rollout status deployment/risk-engine -n $NAMESPACE --timeout=5m

# Step 7: Run smoke tests
echo "Running smoke tests..."
bash scripts/smoke-tests.sh

echo "✅ Rollback complete!"
```

---

## Verification

### **Immediate Checks (T+2 min)**

```bash
# 1. Are pods running?
kubectl get pods -n trading | grep -E "order|market|risk|api-gateway"
# Expected: All Running, 0 restarts (or same as before)

# 2. What version are we on?
kubectl get deployment -n trading -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].image}{"\n"}{end}'

# 3. Are requests succeeding?
kubectl logs -n trading -l app=order-service --tail=20 | grep -c "error"
# Expected: 0 or very low

# 4. Check metrics
kubectl port-forward -n monitoring svc/prometheus-server 9090:80 &
# Prometheus query: rate(http_requests_total{service="order-service",status=~"5.."}[1m])
# Expected: < 0.1%
```

### **Validation Checks (T+5 min)**

```bash
# 1. Run smoke tests
bash scripts/smoke-tests.sh
# Expected: All tests pass

# 2. Run integration tests
bash scripts/integration-tests.sh
# Expected: Order flow works end-to-end

# 3. Check dashboards
# Visit: https://grafana.radix-hft.com/d/trading-ops
# Expected: All metrics green, error rate < 0.1%

# 4. Verify data consistency
kubectl exec -it deployment/order-service -n trading -- \
  curl http://api-gateway:8080/health
# Expected: 200 OK
```

---

## Common Issues & Fixes

### **Issue: Rollback Hangs (ImagePullBackOff)**

```bash
# Old image no longer in registry?
kubectl describe pod -n trading -l app=order-service | grep -A 5 "Failed"

# Solution: Check image exists
aws ecr describe-images --registry-id ACCOUNT_ID --repository-name radix-hft/order-service

# If missing, push from local:
docker pull ghcr.io/radix-hft/order-service:DESIRED_TAG
docker push ghcr.io/radix-hft/order-service:DESIRED_TAG
```

### **Issue: Rollback Succeeded but Still Broken**

```bash
# Rollback only changes code, not config
# Check if config changed in deployment

# Revert config separately
kubectl patch configmap order-service-config -n trading \
  -p '{"data":{"KEY":"PREVIOUS_VALUE"}}'

kubectl rollout restart deployment/order-service -n trading
```

### **Issue: Can't Find Previous Good Revision**

```bash
# Check what versions are deployed
kubectl get all -n trading -o yaml | grep "image:"

# Check git for tags
git tag -l "release-*" | sort -V | tail -5

# Check image registry for available tags
aws ecr list-images --repository-name radix-hft/order-service --query 'imageIds[].imageTag' | grep -v "latest"
```

---

## Post-Rollback

### **Immediately (T+15 min)**
- [ ] Notify stakeholders (incident resolved)
- [ ] Verify monitoring shows green
- [ ] Create incident postmortem issue

### **Within 24 Hours**
- [ ] Root cause analysis
- [ ] Determine if issue is in code or deployment
- [ ] Fix root cause before re-deploy

### **Within 1 Week**
- [ ] Deploy fix to staging
- [ ] Test thoroughly
- [ ] Deploy to production with extra monitoring

---

## Prevention

### **Pre-deployment Checklist**
- [ ] Run smoke tests in staging
- [ ] Run load tests (k6) in staging
- [ ] Code review + approval
- [ ] Canary deployment (5% → 25% → 100%)
- [ ] Monitor error rate and latency during rollout

### **Deployment Best Practices**
- [ ] Always use canary deployments (not big-bang)
- [ ] Have readiness probes set correctly
- [ ] Monitor P99 latency (not just average)
- [ ] Use feature flags for high-risk changes
- [ ] Have rollback plan before deploying

---

## Emergency Contacts

| Role | Name | Slack | Phone |
|---|---|---|---|
| Incident Commander | Alice Johnson | @alice | +1-555-0100 |
| Order Service Lead | Bob Chen | @bob | +1-555-0101 |
| VP Engineering | David Park | @david | +1-555-0102 |

---

**Last Updated:** 2026-06-19  
**Maintained By:** DevOps Team

**Related Runbooks:**
- [Order Service Degradation](./order-service-degradation.md)
- [Market Data Outage](./market-data-outage.md)
- [Node Failure Recovery](./node-failure.md)
