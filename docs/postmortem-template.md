# Incident Postmortem — Radix HFT

**Incident ID:** `[INCIDENT-XXXX]`  
**Date:** `[YYYY-MM-DD]`  
**Duration:** `[HH:MM] UTC`  
**Severity:** `[P0/P1/P2]`  
**Status:** `[Draft/Final]`

---

## Executive Summary

Provide a brief, non-technical summary suitable for leadership. Include:
- What happened in plain language
- Impact on business/users (orders lost, latency, availability %)
- Root cause in one sentence
- Primary action item to prevent recurrence

**Example:**
> On 2026-06-19, Order Service experienced a 12-minute outage due to database connection pool exhaustion. All order submissions failed during this window. ~450 orders were lost. The root cause was a market spike that triggered 100x concurrent order requests, exceeding the configured pool limit of 50. We will increase the pool limit to 200 and add circuit breaker protection.

---

## Incident Timeline

| Time (UTC) | Event | Owner |
|---|---|---|
| 14:23:00 | Market opens; volatility spike (VIX +45%) | — |
| 14:23:15 | Order request rate spikes to 50K/sec (normal: 5K/sec) | — |
| 14:23:45 | Order Service database connections exceed limit | Monitoring |
| 14:24:00 | **Incident begins:** Order submissions start failing with 503 errors | Order Service team |
| 14:24:30 | PagerDuty alert fired; team notified | Alerting |
| 14:25:15 | Team confirms database connection pool exhaustion | Database logs |
| 14:26:00 | Temporary mitigation: scale Order Service replicas 3→8 | Deployment |
| 14:26:45 | New replicas come online; request distribution improves | Kubernetes |
| 14:28:00 | Error rate drops below 5%; stable at 50K/sec | Monitoring |
| 14:35:30 | **Incident ends:** All metrics green; order backlog cleared | — |
| 15:00:00 | Postmortem kick-off meeting | Incident Commander |

---

## Root Cause Analysis (5 Whys)

1. **Why did order submissions fail?**
   - Database connection pool was exhausted (limit: 50 connections).

2. **Why was the pool exhausted?**
   - Market spike caused 100x surge in order request rate (5K→50K/sec).
   - Each request opened a new DB connection but didn't release quickly enough.

3. **Why didn't connections release quickly?**
   - Long-running transaction in risk engine (~500ms per query).
   - Connection pool timeout was too high (30s), causing connections to hang.

4. **Why wasn't this caught before?**
   - Load tests capped at 10K req/sec; real spike reached 50K req/sec.
   - No circuit breaker to shed load before DB exhaustion.
   - Alert threshold was set at 80 connections; spike jumped to 100+ too fast.

5. **Why did the load test not catch this?**
   - Staging environment was sized smaller than production.
   - Load test only simulated steady-state; no spike scenarios.

---

## Impact Assessment

| Metric | Impact | Evidence |
|---|---|---|
| **Availability** | 0% for 12 minutes | Splunk logs: 503 errors 14:24–14:36 |
| **Orders Lost** | ~450 orders | Order database audit: gap in sequence IDs |
| **Recovery Time** | 12 minutes | Timeline above |
| **Revenue Loss** | ~$18K | 450 orders × avg $40 fee |
| **Customer Complaints** | 23 tickets | Zendesk queue |

---

## Contributing Factors (What went wrong)

### 1. **Undersized Connection Pool** ⚠️ CRITICAL
- **Issue:** DB connection limit of 50 was too low for peak load.
- **Why:** Configured based on old production baseline; load profiles changed post-IPO.
- **Evidence:** Prometheus metric `db_connections_in_use` reached 100% at 14:23:45.

### 2. **Missing Circuit Breaker** ⚠️ CRITICAL
- **Issue:** No load shedding mechanism; requests queued indefinitely.
- **Why:** Circuit breaker story was deprioritized in Q2 sprint.
- **Evidence:** Grafana dashboard shows request queue depth spike to 10K.

### 3. **Inadequate Load Testing** ⚠️ HIGH
- **Issue:** Load tests didn't simulate market spike scenarios.
- **Why:** Test scenarios created 6 months ago; no review/updates for new features.
- **Evidence:** Staging max load was 10K req/sec vs. production peak of 50K req/sec.

### 4. **Slow Risk Engine Queries** ⚠️ MEDIUM
- **Issue:** Risk check taking ~500ms per order (expected: <5ms).
- **Why:** Newly added Position Aggregation query was N+1 (cartesian product on position_id).
- **Evidence:** APM traces: `risk_check_duration_p99` = 523ms vs. SLO of 5ms.

### 5. **Alert Threshold Too High** ⚠️ MEDIUM
- **Issue:** Alert only fired at 80 connections; spike went to 100+ in 30 seconds.
- **Why:** Threshold was set to avoid noise during normal peak hours.
- **Evidence:** Alert rule: `db_connections_in_use > 80` didn't fire until 14:24:30.

---

## What Went Right ✓

1. **Fast Detection:** Monitoring caught the spike within 45 seconds of market event.
2. **Rapid Response:** Team triaged and scaled in under 2 minutes.
3. **Graceful Degradation:** Order Service didn't crash; returned 503 errors (proper failure mode).
4. **Good Observability:** Prometheus/Grafana helped identify the exact bottleneck.
5. **Automatic Rollback:** Failed orders were not persisted; no data corruption.

---

## Corrective Actions

### Immediate (Within 24 hours)

| Action | Owner | Due | Status |
|---|---|---|---|
| **Increase DB connection pool limit from 50 → 200** | @db-infra | 2026-06-19 | 🔄 In Progress |
| **Lower connection timeout from 30s → 5s** | @db-infra | 2026-06-19 | 🔄 In Progress |
| **Deploy to staging + smoke test** | @devops | 2026-06-19 | ⏳ Pending |
| **Deploy to production (canary)** | @devops | 2026-06-20 | ⏳ Pending |

**Rationale:** Quick wins to prevent immediate recurrence. Increases headroom by 4x.

### Short-term (Within 1 week)

| Action | Owner | Due | Epic |
|---|---|---|---|
| **Fix N+1 risk engine query** | @backend-risk | 2026-06-22 | Risk-2024-Q3 |
| **Add circuit breaker to Order Service** | @backend-orders | 2026-06-25 | Resilience-2024 |
| **Implement circuit breaker integration tests** | @qa | 2026-06-25 | Resilience-2024 |
| **Create spike load test scenario** | @test-infra | 2026-06-23 | Load-Testing-2024 |

**Rationale:** Address root causes to prevent similar incidents.

### Long-term (Within 1 month)

| Action | Owner | Due | Epic |
|---|---|---|---|
| **Add adaptive connection pooling (HIKARI-based)** | @db-infra | 2026-07-10 | Database-2024 |
| **Implement bulkhead isolation per account** | @backend-orders | 2026-07-15 | Resilience-2024 |
| **Establish quarterly load test review cadence** | @test-infra | 2026-06-30 | Process-2024 |
| **Add market condition correlation to alert rules** | @monitoring | 2026-07-05 | Monitoring-2024 |

**Rationale:** Systemic improvements to prevent classes of similar incidents.

---

## Lessons Learned

### What We Learned

1. **Load test scenarios must evolve with production traffic.**
   - Our staging tests assumed steady-state; production experiences spikes.
   - Action: Create market spike, thundering herd, and failure cascade scenarios.

2. **Connection pool sizing must account for tail latency, not just mean.**
   - We sized for mean risk check time (5ms), but P99 was 100x higher.
   - Action: Use P99 latency × max concurrency formula for pool sizing.

3. **Circuit breakers save response time under overload.**
   - Requests waiting in queue for 30+ seconds is worse than failing fast.
   - Action: Prioritize circuit breaker implementation (was deferred).

4. **Alert thresholds during market volatility need adjustment.**
   - Fixed thresholds don't account for regime changes.
   - Action: Implement adaptive alerting based on market conditions.

### Questions for Discussion

- Should we have separate connection pools for order submission vs. background jobs?
- Could we use adaptive timeout based on request queue depth?
- Do we need multi-region failover for market spike resilience?
- Should order service replicas be pre-scaled during known high-vol windows (e.g., market open)?

---

## Communication & Follow-up

### Internal Communication
- ✅ **Slack:** Posted incident summary to #trading-incidents
- ✅ **Email:** Sent incident report to exec stakeholders
- ⏳ **All-hands:** Scheduled postmortem walkthrough for 2026-06-21 at 10am PT

### External Communication
- ✅ **Customer Notification:** Sent email to affected account holders
- ✅ **Status Page:** Updated status.radix-hft.com with incident details
- ⏳ **Press:** No media outreach needed (internal incident)

### Customer Impacts
- Affected accounts: 47
- Orders lost: ~450
- Average loss per account: ~$383
- Credits issued: $170K (50% of revenue impact)

---

## Appendix: Evidence & Logs

### Key Metrics (Grafana Snapshot)
- [Snapshot: Connection Pool Exhaustion](https://grafana.radix-hft.com/d/ordering-metrics/snapshots/2026-06-19-1424)
- [Snapshot: Error Rate Spike](https://grafana.radix-hft.com/d/trading-ops/snapshots/2026-06-19-1423)

### Database Logs
```sql
-- Connection pool exhausted at 14:23:45
SELECT COUNT(*) FROM pg_stat_activity WHERE datname = 'radix_hft';
-- Result: 100 connections (limit was 50)

-- Long-running risk check query
SELECT * FROM pg_stat_statements WHERE query LIKE '%position%' ORDER BY mean_time DESC;
-- Result: avg 523ms (SLO: 5ms)
```

### Application Logs
```
2026-06-19T14:23:45Z ERROR order-service: Cannot acquire DB connection: timeout after 30s
2026-06-19T14:24:00Z ERROR order-service: 1247 failed order submissions (pool exhausted)
2026-06-19T14:26:00Z INFO order-service: Scaled to 8 replicas
2026-06-19T14:28:00Z INFO order-service: Incident resolved; error rate <1%
```

---

## Sign-off

| Role | Name | Date | Status |
|---|---|---|---|
| **Incident Commander** | Alice Johnson | 2026-06-19 | ✅ Approved |
| **Order Service Lead** | Bob Chen | 2026-06-20 | ✅ Approved |
| **Database Ops Lead** | Carol Williams | 2026-06-20 | ✅ Approved |
| **VP Engineering** | David Park | 2026-06-20 | ✅ Approved |

---

**Document Version:** 1.0  
**Last Updated:** 2026-06-20  
**Next Review:** 2026-07-20
