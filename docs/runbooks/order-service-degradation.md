# Runbook: Order Service Degradation

**Severity:** P0 | **Component:** Order Service | **RTO:** 5 min | **RPO:** 0 min

---

## Symptoms

- Order submissions failing with **503 Service Unavailable** or **504 Gateway Timeout**
- Error rate > 1% for > 2 minutes
- P99 latency > 200ms (SLO breach)
- PagerDuty alert: `OrderServiceHighErrorRate`

**Check Status:**
```bash
# Quick status check
kubectl get pods -n trading -l app=order-service

# Check recent errors
kubectl logs -n trading -l app=order-service --tail=50 | grep -i "error\|panic\|fatal"
```

---

## Immediate Response (0-5 min)

### 1. **Declare Incident**
```bash
# Notify team (Slack)
@incident-commander Order Service degradation detected
- Error rate: [X]%
- P99 latency: [X]ms
- Last good state: [timestamp]
```

### 2. **Assess Severity**
- Is production traffic affected? → Yes = P0, No = P1
- Are orders being lost? → Yes = Page VP Eng
- What is error rate? < 5% = P1, > 5% = P0

### 3. **Collect Diagnostics** (parallel)

**Pod Status:**
```bash
kubectl describe pods -n trading -l app=order-service
# Look for: CrashLoopBackOff, ImagePullBackOff, Pending state
```

**Recent Deployments:**
```bash
kubectl rollout history deployment/order-service -n trading
kubectl describe deployment order-service -n trading | grep -A 20 "Conditions:"
```

**Resource Constraints:**
```bash
kubectl top pods -n trading -l app=order-service --containers
# Check if CPU/memory at limits

kubectl describe nodes | grep -A 5 "Allocated resources"
# Check node capacity
```

**Logs (Last 10 min):**
```bash
kubectl logs -n trading -l app=order-service --since=10m | tail -200
```

**Metrics (Prometheus):**
```bash
# Port-forward to Prometheus
kubectl port-forward -n monitoring svc/prometheus-server 9090:80 &

# Query in browser: localhost:9090
# - rate(http_requests_total{service="order-service",status=~"5.."}[5m])
# - histogram_quantile(0.99, http_request_duration_seconds_bucket{service="order-service"})
```

---

## Root Cause Analysis (Decision Tree)

### **Is Order Service Pod Running?**

❌ **NO:** Pod is down/crashing
- Check logs: `kubectl logs <pod> -n trading`
  - OOMKilled? → Memory limit too low or memory leak
  - Exit code 137? → Out of memory
  - Panic/crash? → Code bug
- → Go to **[Recovery: Pod Crash](#recovery-pod-crash)**

✅ **YES:** Pod is running but request failing
- Check HTTP status:
  - 503 (Service Unavailable)? → Dependent service down
  - 504 (Gateway Timeout)? → Request taking too long
  - 500 (Internal Error)? → Application logic error
- → Go to **[Recovery: Dependency Failure](#recovery-dependency-failure)** or **[Recovery: Timeout](#recovery-timeout)**

### **Are Dependencies Healthy?**

**Database (Aurora):**
```bash
# Check connection
kubectl port-forward -n trading svc/order-service 9000:9000
# Then from pod: psql -h aurora-prod.us-east-1.rds.amazonaws.com -U admin -d radix_hft

# Or check from Prometheus:
# - aws_rds_cpuutilization_average{dbcluster_identifier="radix-hft-prod-aurora"}
# - aws_rds_database_connections_available
```

**Kafka:**
```bash
kubectl exec -it deployment/order-service -n trading -- \
  kafka-broker-api-versions.sh --bootstrap-server $KAFKA_BROKERS
```

**Risk Engine:**
```bash
kubectl logs -n trading -l app=risk-engine | grep -i "error\|timeout"
```

### **Is It Resource Exhaustion?**

```bash
# CPU throttling?
kubectl get --raw /apis/metrics.k8s.io/v1beta1/namespaces/trading/pods | jq '.items[] | select(.metadata.labels.app=="order-service")'

# Memory pressure?
kubectl get events -n trading --sort-by='.lastTimestamp' | grep -i "memory\|evict"

# Disk space?
kubectl exec -it <pod> -n trading -- df -h
```

---

## Recovery Procedures

### **Recovery: Pod Crash**

**Step 1: Check image pull**
```bash
kubectl describe pod <pod> -n trading | grep -A 5 "Events:"
# If ImagePullBackOff: Check image registry credentials, image exists in registry
```

**Step 2: Increase resource limits (temporary)**
```bash
kubectl set resources deployment order-service -n trading \
  --limits=cpu=3000m,memory=4Gi \
  --requests=cpu=1000m,memory=2Gi
```

**Step 3: Force rollout**
```bash
kubectl rollout restart deployment/order-service -n trading
kubectl rollout status deployment/order-service -n trading --timeout=5m
```

**Step 4: If still crashing, rollback**
```bash
# See [Rollback Runbook](./rollback.md)
```

---

### **Recovery: Dependency Failure**

**Database Down?**
```bash
# Check Aurora cluster status
aws rds describe-db-clusters --db-cluster-identifier radix-hft-prod-aurora --region us-east-1 | jq '.DBClusters[0].Status'

# Check connections
aws rds describe-db-instances --region us-east-1 --query 'DBInstances[?DBClusterIdentifier==`radix-hft-prod-aurora`]' | jq '.[].DBInstanceStatus'

# If primary down, manual failover to replica
aws rds failover-db-cluster --db-cluster-identifier radix-hft-prod-aurora --region us-east-1
```

**Kafka Down?**
```bash
# Check broker status
aws kafka list-clusters --region us-east-1 | jq '.ClusterInfoList[]'

# Restart brokers (one at a time, wait for recovery)
# Use AWS console or API

# Scale Order Service to read from replicas (if available)
```

**Risk Engine Down?**
```bash
kubectl logs -n trading -l app=risk-engine --tail=50

# Restart if needed
kubectl rollout restart deployment/risk-engine -n trading
kubectl rollout status deployment/risk-engine -n trading --timeout=5m
```

---

### **Recovery: Timeout**

**Step 1: Check Request Latency**
```bash
# Histogram of request duration
kubectl port-forward -n monitoring svc/prometheus-server 9090:80
# Query: histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[1m]))
```

**Step 2: Identify Slow Operation**
```bash
# Check slow logs
kubectl exec -it <pod> -n trading -- curl http://localhost:6060/debug/pprof/profile?seconds=10 > cpu.prof

# Analyze (outside pod)
go tool pprof cpu.prof
# (pprof) list [slow-function]
```

**Step 3: Increase Timeout (Temporary)**
```bash
# Update Order Service config
kubectl patch configmap order-service-config -n trading \
  -p '{"data":{"ORDER_TIMEOUT_MS":"200"}}'

# Rolling restart
kubectl rollout restart deployment/order-service -n trading
```

**Step 4: Scale Up**
```bash
# Increase replicas
kubectl scale deployment order-service -n trading --replicas=10

# Or adjust HPA
kubectl autoscale deployment order-service -n trading --min=5 --max=20 --cpu-percent=50
```

---

## Validation & Rollback

### **Is Service Recovered?**
```bash
# Check error rate < 0.1%
kubectl exec -it <pod> -n trading -- \
  curl http://prometheus:9090/api/v1/query?query='sum(rate(http_requests_total{service="order-service",status=~"5.."}[5m]))'

# Check P99 latency < 50ms
kubectl exec -it <pod> -n trading -- \
  curl http://prometheus:9090/api/v1/query?query='histogram_quantile(0.99, http_request_duration_seconds_bucket{service="order-service"})'

# Run smoke tests
bash scripts/smoke-tests.sh
```

### **If Recovery Failed: Rollback**

See [Rollback Runbook](./rollback.md)

```bash
# Immediate rollback
kubectl set image deployment/order-service -n trading \
  order-service=ghcr.io/radix-hft/order-service:PREVIOUS_VERSION

# Wait for rollout
kubectl rollout status deployment/order-service -n trading --timeout=5m
```

---

## Escalation Path

| Time | Action | Owner |
|---|---|---|
| T+0 | Incident declared | On-call engineer |
| T+5m | No progress? | Escalate to Order Service lead |
| T+15m | Still degraded? | Page incident commander |
| T+30m | P0 ongoing? | Escalate to VP Engineering |

---

## Post-Incident

### **Immediate (Next 24h)**
- [ ] Create postmortem (see [template](../postmortem-template.md))
- [ ] Identify root cause
- [ ] Document temporary vs. permanent fixes

### **Short-term (Week 1)**
- [ ] Implement permanent fix
- [ ] Update runbook based on learnings
- [ ] Add monitoring/alerting for early detection

### **Long-term (Month)**
- [ ] Add load test scenario to prevent regression
- [ ] Review dependency resilience (circuit breaker, retry logic)

---

## Useful Commands Reference

```bash
# Real-time metrics stream
watch -n 1 'kubectl top pods -n trading -l app=order-service --containers'

# Follow logs across all replicas
kubectl logs -f -n trading -l app=order-service --all-containers=true --prefix=true

# Interactive shell on pod
kubectl exec -it deployment/order-service -n trading -- /bin/bash

# Describe pod details
kubectl describe pod -n trading -l app=order-service | head -100

# Port-forward to service
kubectl port-forward -n trading svc/order-service 8080:8080

# Restart deployment
kubectl rollout restart deployment/order-service -n trading
kubectl rollout status deployment/order-service -n trading

# View recent events
kubectl get events -n trading --sort-by='.lastTimestamp' | tail -20

# Check HPA status
kubectl get hpa -n trading order-service -o wide
kubectl describe hpa order-service -n trading
```

---

**Last Updated:** 2026-06-19  
**Maintained By:** Order Service Team
