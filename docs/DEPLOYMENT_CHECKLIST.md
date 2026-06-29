# Deployment Checklist

Complete this checklist before every production deployment.

---

## Pre-Deployment (24h before)

### Planning
- [ ] Deployment window scheduled (low-traffic hours if possible)
- [ ] Team members notified and available
- [ ] Rollback plan documented
- [ ] Monitoring alerts configured
- [ ] Runbooks reviewed

### Code Readiness
- [ ] All tests passing on main branch
- [ ] Code review completed and approved
- [ ] No failing security scans
- [ ] Lint checks passing
- [ ] Docker images built and scanned

### Infrastructure Readiness
- [ ] Staging deployment successful
- [ ] Load tests passed on staging
- [ ] Database migrations tested
- [ ] Secrets/credentials prepared
- [ ] Capacity planning done (CPU, memory, disk)

### Communication
- [ ] Status page prepared
- [ ] Customer communication drafted (if needed)
- [ ] Slack channels notified
- [ ] PagerDuty updated with deployment window

---

## Immediately Before Deployment

### Final Verification
- [ ] Main branch is clean (no uncommitted changes)
- [ ] Deployment artifacts ready:
  - [ ] Docker images tagged correctly
  - [ ] Helm chart version bumped
  - [ ] All manifests validated
- [ ] Cluster connectivity verified:
  ```bash
  kubectl cluster-info
  kubectl get nodes
  ```
- [ ] Current metrics baseline captured:
  - [ ] Error rate < 0.1%
  - [ ] P99 latency baseline
  - [ ] Node resource utilization
- [ ] Recent deployment history reviewed:
  ```bash
  helm history trading-platform -n trading | head -5
  kubectl rollout history deployment/order-service -n trading
  ```

### Monitoring & Alerting
- [ ] Prometheus/Grafana dashboards open
- [ ] Alert rules verified
- [ ] PagerDuty escalation configured
- [ ] Slack notifications enabled
- [ ] Logs aggregation working

### Team & Communication
- [ ] Incident commander identified
- [ ] Oncall engineer available
- [ ] Slack channel monitoring (#trading-deployments)
- [ ] No critical ongoing incidents
- [ ] Stakeholders standing by

---

## During Deployment

### Initial Rollout (Canary Phase)
- [ ] Canary replicas (5%) deployed
- [ ] Health checks passing
- [ ] Error rate remains < 0.1%
- [ ] P99 latency within SLO
- [ ] Monitor for 5 minutes minimum

### Escalation (25%)
- [ ] Canary metrics still good
- [ ] Analysis passed (if using Argo Rollouts)
- [ ] Scale to 25% of replicas
- [ ] Monitor for 10 minutes minimum
- [ ] Check error budget burn rate

### Full Rollout (100%)
- [ ] 25% phase metrics good
- [ ] Scale to 100% of replicas
- [ ] Monitor carefully for 15 minutes
- [ ] Check all pods are Running
- [ ] Verify no pod restarts

### Validation
After each phase:
```bash
# Pod status
kubectl get pods -n trading -o wide

# Deployment status
kubectl rollout status deployment/order-service -n trading

# Error rate
kubectl logs -n trading -l app=order-service --tail=20 | grep -c "error"

# Metrics
# (Via Prometheus/Grafana)
# - rate(http_requests_total{status=~"5.."}[1m])
# - histogram_quantile(0.99, http_request_duration_seconds_bucket)
```

### Success Criteria for Each Phase
**Canary & Escalation:**
- [ ] Error rate < 1% (target: < 0.1%)
- [ ] P99 latency < 100ms (target: < 50ms)
- [ ] No increase in pod restarts
- [ ] No memory leaks visible
- [ ] CPU usage reasonable

**Full Rollout:**
- [ ] All metrics green
- [ ] Error rate < 0.1%
- [ ] P99 latency < 50ms
- [ ] Order throughput normal
- [ ] No pending pods or evictions

---

## Post-Deployment (Immediate)

### Smoke Tests
```bash
# Run automated smoke tests
bash scripts/smoke-tests.sh

# Manual verification
# 1. Submit test order
curl -X POST https://api.radix-hft.com/v1/orders \
  -H "Content-Type: application/json" \
  -d '{"symbol":"TEST","quantity":1,"price":100}'

# 2. Check order status
# 3. Verify market data feed
# 4. Check risk engine response time
```

### Metrics & Monitoring
- [ ] Error rate stable (< 0.1%)
- [ ] Latency stable (< 50ms P99)
- [ ] No spike in pod restarts
- [ ] Memory/CPU usage normal
- [ ] No alerts firing
- [ ] Kafka lag acceptable
- [ ] Database connections normal

### Logs
- [ ] No error messages in logs
- [ ] No warnings indicating issues
- [ ] Deployment logs show successful rollout
- [ ] No application panics or crashes

### Notifications
- [ ] Team notified: "Deployment successful"
- [ ] Status page updated (if was posted)
- [ ] PagerDuty marked resolved
- [ ] Slack notification sent

---

## Post-Deployment (1-24 hours)

### Continuous Monitoring
- [ ] Check dashboard every 30 minutes for first 2 hours
- [ ] Monitor error logs hourly for next 12 hours
- [ ] Watch for customer complaints/tickets
- [ ] Check SLO metrics are met

### Data Validation
- [ ] Order counts match expectations
- [ ] No data corruption detected
- [ ] Database replication lag normal
- [ ] Kafka topic offsets healthy

### Performance
- [ ] No performance degradation seen
- [ ] User experience unchanged or improved
- [ ] Cost metrics within expectations

### Post-Mortem (if issues)
- [ ] Document any issues observed
- [ ] Create incident report
- [ ] Schedule postmortem meeting
- [ ] Plan preventive actions

---

## Rollback Decision Tree

**Should we rollback?**

❌ **YES, Rollback Immediately If:**
- Error rate > 5% (sustained > 2 min)
- P99 latency > 200ms (sustained > 2 min)
- Data corruption detected
- Service completely unavailable
- Critical security issue discovered

⚠️ **Maybe, Discuss If:**
- Error rate 1-5%
- P99 latency 100-200ms
- Single service affected
- Issue has workaround

✅ **NO, Monitor If:**
- Error rate < 1%
- P99 latency < 100ms
- Isolated to single pod/region
- Temporary (transient) issue

**If Rolling Back:**
```bash
# Helm rollback
helm rollback trading-platform -n trading --wait

# Or Kubernetes rollback
kubectl rollout undo deployment/order-service -n trading

# Monitor rollback
kubectl rollout status deployment/order-service -n trading

# Verify
bash scripts/smoke-tests.sh
```

---

## Post-Incident (if rollback needed)

- [ ] Document what went wrong
- [ ] Create postmortem
- [ ] Identify preventive actions
- [ ] Schedule follow-up improvements
- [ ] Update this checklist if needed

---

## Sign-Off

**Deployment Conducted By:** ________________  
**Date/Time:** ________________  
**Duration:** ________________  
**Result:** ☐ Success  ☐ Rollback  

**Verified By:** ________________  
**Approver:** ________________  

---

## Common Issues & Quick Fixes

| Issue | Quick Fix |
|-------|-----------|
| Pod CrashLoopBackOff | Check logs: `kubectl logs <pod>` |
| ImagePullBackOff | Verify image exists in registry |
| Pending pods | Check resource availability: `kubectl top nodes` |
| High error rate | Check dependent services (DB, Kafka, Redis) |
| High latency | Scale up replicas or check load |
| Memory leak | Monitor memory growth and restart if needed |

---

**Keep this checklist visible during deployment!**

**Questions?** See [docs/runbooks/](./docs/runbooks/) for detailed procedures.

Last updated: 2026-06-19
