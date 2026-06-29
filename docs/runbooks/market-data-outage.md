# Runbook: Market Data Outage

**Severity:** P0 | **Component:** Market Data Service | **RTO:** 2 min | **RPO:** 0 min

---

## Symptoms

- Market data feed lag > 100ms (P99)
- Feed disconnected: NASDAQ, NYSE, or CME
- Order Service unable to validate prices
- Real-time market snapshot > 5 min old
- PagerDuty: `MarketDataFeedLagHigh` or `MarketDataFeedDisconnected`

**Check Status:**
```bash
kubectl logs -n trading -l app=market-data-service --tail=30 | grep -i "disconnect\|lag\|error"

kubectl get pods -n trading -l app=market-data-service
```

---

## Immediate Response (0-2 min)

### **1. Declare Incident**
```bash
@incident-commander Market data outage detected
Affected feeds: [NASDAQ/NYSE/CME]
Last quote received: [timestamp]
Current lag: [X]ms
```

### **2. Check Which Feeds Are Down**

```bash
# Market Data Service logs
kubectl logs -n trading -l app=market-data-service --tail=50 | grep -E "connect|feed|NASDAQ|NYSE|CME"

# Expected healthy: "feed.nasdaq.up", "feed.nyse.up", "feed.cme.up"
# Expected down: "feed.nasdaq.error: disconnected", etc.
```

### **3. Check Feed Health**

```bash
# NASDAQ status
curl -s https://www.nasdaq.com/status | grep "market_status"

# CME status
curl -s https://www.cmegroup.com/tools/systemstatus/ | grep -i "status"

# NYSE status
curl -s https://www.nyse.com/ | grep -i "market.*open"
```

### **4. Assess Business Impact**

- Can orders be rejected? → Use fallback pricing
- How many accounts affected? → Check active orders
- Is order submission blocked? → Scale down acceptance

```bash
# Check pending orders count
kubectl exec -it deployment/order-service -n trading -- \
  curl http://api-gateway:8080/v1/stats | jq '.pending_orders'
```

---

## Root Cause Analysis

### **Is Market Data Service Pod Running?**

```bash
kubectl describe pods -n trading -l app=market-data-service
# Look for: CrashLoopBackOff, ImagePullBackOff, OOMKilled
```

❌ **Pod not running:**
- Check logs: `kubectl logs <pod> -n trading`
- Restart: `kubectl rollout restart deployment/market-data-service -n trading`
- → Go to **[Recovery: Service Restart](#recovery-service-restart)**

✅ **Pod running but disconnected:**
- → Go to **[Recovery: Feed Reconnection](#recovery-feed-reconnection)**

### **Is Exchange Feed Actually Down?**

```bash
# Check NASDAQ
ping -c 1 nasdaq.mrdata.com

# Check NYSE
ping -c 1 nyse.mrdata.com

# Check CME
ping -c 1 cme.mktdata.com
```

✅ **Exchange reachable:** Feed disconnection is likely app issue  
❌ **Exchange unreachable:** Likely exchange outage or network issue

---

## Recovery Procedures

### **Recovery: Service Restart**

```bash
# Restart Market Data Service
kubectl rollout restart deployment/market-data-service -n trading
kubectl rollout status deployment/market-data-service -n trading --timeout=5m

# Monitor logs
kubectl logs -n trading -l app=market-data-service -f --all-containers=true
```

**Expected behavior:**
```
[2026-06-19T14:25:10Z] Connecting to NASDAQ feed...
[2026-06-19T14:25:11Z] Connected to NASDAQ (session_id: 12345)
[2026-06-19T14:25:12Z] Subscribed to symbols: [AAPL, MSFT, GOOG, ...]
[2026-06-19T14:25:13Z] Feed is live (lag: 2ms)
```

---

### **Recovery: Feed Reconnection**

If feed is reachable but service reports disconnected:

```bash
# Check feed configuration
kubectl get configmap -n trading market-data-service-config -o yaml | grep -A 20 "feeds:"

# Check credentials
kubectl get secret -n trading market-data-feed-credentials -o yaml
# Make sure credentials aren't expired

# Force reconnect
kubectl set env deployment/market-data-service -n trading RECONNECT_FORCE=true
kubectl rollout restart deployment/market-data-service -n trading
kubectl rollout status deployment/market-data-service -n trading --timeout=5m

# Remove forced flag
kubectl set env deployment/market-data-service -n trading RECONNECT_FORCE-
```

---

### **Recovery: Fallback to Cached Data**

If feed is down and can't reconnect:

```bash
# Option 1: Use last known good snapshot (within 5 min)
kubectl patch configmap market-data-service-config -n trading \
  -p '{"data":{"FALLBACK_MODE":"cache","CACHE_STALENESS_MAX_MS":"300000"}}'

kubectl rollout restart deployment/market-data-service -n trading

# Check status
kubectl logs -n trading -l app=market-data-service --tail=20 | grep -i "fallback\|cache"
```

**Warning:** Trading with > 5 min old prices is risky!

### **Recovery: Drain Orders & Hold Traffic**

If multi-feed outage (can't get any prices):

```bash
# 1. Stop accepting new orders
kubectl patch configmap order-service-config -n trading \
  -p '{"data":{"ACCEPT_ORDERS":"false"}}'

kubectl rollout restart deployment/order-service -n trading

# 2. Message customers
# "Market data feeds are temporarily unavailable. New orders are on hold."

# 3. Once feeds recover, resume
kubectl patch configmap order-service-config -n trading \
  -p '{"data":{"ACCEPT_ORDERS":"true"}}'

kubectl rollout restart deployment/order-service -n trading
```

---

## Network-Level Diagnostics

If feeds are unreachable:

```bash
# From order service pod, test connectivity
kubectl exec -it deployment/order-service -n trading -- bash
$ nc -zv nasdaq.mrdata.com 443
$ nc -zv nyse.mrdata.com 443
$ nc -zv cme.mktdata.com 443

# Check DNS resolution
$ nslookup nasdaq.mrdata.com
$ nslookup nyse.mrdata.com

# Check routing
$ traceroute nasdaq.mrdata.com
```

**If DNS fails:** Contact network team (NAT gateway issue?)  
**If routing fails:** Contact AWS support (BGP issue)  
**If TLS fails:** Check certificate: `openssl s_client -connect nasdaq.mrdata.com:443`

---

## Scale & Fallback Strategy

### **If Outage Persists > 15 min:**

```bash
# Option A: Reduce order throughput
kubectl scale deployment order-service -n trading --replicas=5
kubectl patch configmap order-service-config -n trading \
  -p '{"data":{"MAX_ORDERS_PER_SECOND":"10000"}}'

# Option B: Enable circuit breaker
kubectl patch configmap order-service-config -n trading \
  -p '{"data":{"CIRCUIT_BREAKER_ENABLED":"true","CIRCUIT_BREAKER_THRESHOLD":"0.5"}}'

# Option C: Manual price override (temporary)
# Inject fixed prices for critical symbols
kubectl patch configmap market-data-service-config -n trading \
  -p '{"data":{"MANUAL_PRICES":"{\"AAPL\": 150.00, \"MSFT\": 300.00}"}}'
```

---

## Validation & Recovery

### **When Feed Comes Back Online**

```bash
# Monitor lag decrease
watch -n 1 'kubectl logs -n trading -l app=market-data-service --tail=1 | grep "lag:"'

# Check metrics
kubectl port-forward -n monitoring svc/prometheus-server 9090:80 &
# Query: histogram_quantile(0.99, rate(market_data_feed_lag_milliseconds_bucket[1m]))
# Expected: < 100ms
```

### **Smoke Tests**

```bash
# Verify order flow still works
bash scripts/smoke-tests.sh

# Verify prices are fresh (< 5 sec old)
kubectl exec -it deployment/order-service -n trading -- \
  curl http://api-gateway:8080/v1/market-data?symbol=AAPL | jq '.timestamp'

# Should be within last 5 seconds
```

---

## Post-Incident

### **During Outage (Periodic)**
- [ ] Alert customers every 5 min (status.radix-hft.com)
- [ ] Check if partial feeds available (e.g., just NASDAQ)
- [ ] Monitor for secondary impacts (stuck orders, reconciliation issues)

### **After Recovery (24h)**
- [ ] Contact exchange support (why did feed disconnect?)
- [ ] Review logs for connection issues
- [ ] Check for accumulated orders during outage
- [ ] Reconcile trades with exchange

### **Preventive (Week)**
- [ ] Add multi-source market data (backup feed provider)
- [ ] Implement circuit breaker for price staleness
- [ ] Add health checks to exchange connectivity
- [ ] Test failover scenarios quarterly

---

## Escalation

| Time | Action | Owner |
|---|---|---|
| T+0 | Incident declared | On-call |
| T+5m | Still down? | Market Data Service lead |
| T+15m | No feed recovery ETA? | VP Engineering |
| T+30m | P0 affecting trading? | CEO/CRO notification |

---

## Related Runbooks

- [Order Service Degradation](./order-service-degradation.md)
- [Rollback](./rollback.md)
- [Node Failure](./node-failure.md)

---

**Last Updated:** 2026-06-19  
**Maintained By:** Market Data Team
