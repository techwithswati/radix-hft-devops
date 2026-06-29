#!/bin/bash
##############################################################
# Canary Health Check — Radix HFT
# Monitor health during canary rollout
##############################################################

set -euo pipefail

NAMESPACE="${NAMESPACE:-trading}"
SERVICE="${SERVICE:-order-service}"
CANARY_PERCENTAGE="${CANARY_PERCENTAGE:-5}"
CHECK_INTERVAL="${CHECK_INTERVAL:-10}"  # seconds
CHECK_DURATION="${CHECK_DURATION:-300}"  # 5 minutes
ERROR_THRESHOLD="${ERROR_THRESHOLD:-1}"  # % error rate threshold

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[CANARY]${NC} $1"
}

pass() {
    echo -e "${GREEN}✓${NC} $1"
}

fail() {
    echo -e "${RED}✗${NC} $1"
}

warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# ────────────────────────────────────────────────────
# Get canary pod count
# ────────────────────────────────────────────────────
get_canary_pods() {
    kubectl get rollout $SERVICE -n $NAMESPACE -o jsonpath='{.status.canary.replicas}' 2>/dev/null || echo "0"
}

# ────────────────────────────────────────────────────
# Get stable pod count
# ────────────────────────────────────────────────────
get_stable_pods() {
    kubectl get rollout $SERVICE -n $NAMESPACE -o jsonpath='{.status.stable.replicas}' 2>/dev/null || echo "0"
}

# ────────────────────────────────────────────────────
# Get error rate from metrics
# ────────────────────────────────────────────────────
get_error_rate() {
    kubectl port-forward -n monitoring svc/prometheus-server 9090:80 &>/dev/null &
    sleep 2
    
    local error_rate=$(curl -s 'http://localhost:9090/api/v1/query?query=rate(http_requests_total{service="'$SERVICE'",status=~"5.."}[1m])' | \
        grep -o '"value":"\([^"]*\)"' | head -1 | cut -d'"' -f4)
    
    pkill -f "port-forward" 2>/dev/null || true
    echo "${error_rate:-0}"
}

# ────────────────────────────────────────────────────
# Get P99 latency
# ────────────────────────────────────────────────────
get_p99_latency() {
    kubectl port-forward -n monitoring svc/prometheus-server 9090:80 &>/dev/null &
    sleep 2
    
    local latency=$(curl -s 'http://localhost:9090/api/v1/query?query=histogram_quantile(0.99,http_request_duration_seconds_bucket{service="'$SERVICE'"})' | \
        grep -o '"value":"\([^"]*\)"' | head -1 | cut -d'"' -f4)
    
    pkill -f "port-forward" 2>/dev/null || true
    echo "${latency:-0}"
}

# ────────────────────────────────────────────────────
# Check pod health
# ────────────────────────────────────────────────────
check_pod_health() {
    local pod=$1
    
    if kubectl get pod $pod -n $NAMESPACE &>/dev/null; then
        local status=$(kubectl get pod $pod -n $NAMESPACE -o jsonpath='{.status.phase}')
        local restarts=$(kubectl get pod $pod -n $NAMESPACE -o jsonpath='{.status.containerStatuses[0].restartCount}')
        
        if [ "$status" = "Running" ] && [ "$restarts" -eq 0 ]; then
            return 0
        fi
    fi
    return 1
}

# ────────────────────────────────────────────────────
# Main health check loop
# ────────────────────────────────────────────────────
monitor_canary() {
    log "======================================"
    log "Canary Health Check: $SERVICE"
    log "Namespace: $NAMESPACE"
    log "Target: $CANARY_PERCENTAGE% canary"
    log "Duration: $CHECK_DURATION seconds"
    log "======================================"
    
    local start_time=$(date +%s)
    local max_error_rate=0
    local max_latency=0
    local health_checks_failed=0
    
    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        if [ $elapsed -ge $CHECK_DURATION ]; then
            break
        fi
        
        log ""
        log "Check #$((elapsed / CHECK_INTERVAL + 1)) (elapsed: ${elapsed}s)"
        
        # Get metrics
        local canary_pods=$(get_canary_pods)
        local stable_pods=$(get_stable_pods)
        local error_rate=$(get_error_rate)
        local p99_latency=$(get_p99_latency)
        
        log "Canary pods: $canary_pods, Stable pods: $stable_pods"
        log "Error rate: ${error_rate}%, P99 latency: ${p99_latency}ms"
        
        # Check error rate
        if (( $(echo "$error_rate > $ERROR_THRESHOLD" | bc -l) )); then
            fail "Error rate exceeds threshold: ${error_rate}% > ${ERROR_THRESHOLD}%"
            ((health_checks_failed++))
        else
            pass "Error rate OK: ${error_rate}%"
        fi
        
        # Check latency
        if (( $(echo "$p99_latency > 100" | bc -l) )); then
            warn "P99 latency elevated: ${p99_latency}ms (target: <50ms)"
        else
            pass "P99 latency OK: ${p99_latency}ms"
        fi
        
        # Track max values
        if (( $(echo "$error_rate > $max_error_rate" | bc -l) )); then
            max_error_rate=$error_rate
        fi
        if (( $(echo "$p99_latency > $max_latency" | bc -l) )); then
            max_latency=$p99_latency
        fi
        
        # Check pod health
        local canary_pod=$(kubectl get pod -n $NAMESPACE -l app=$SERVICE,version=canary -o name | head -1 2>/dev/null)
        if [ -n "$canary_pod" ]; then
            if check_pod_health "$canary_pod"; then
                pass "Canary pod healthy: $canary_pod"
            else
                fail "Canary pod unhealthy: $canary_pod"
                ((health_checks_failed++))
            fi
        fi
        
        sleep $CHECK_INTERVAL
    done
    
    log ""
    log "======================================"
    log "Canary Health Check Results"
    log "======================================"
    log "Max error rate: ${max_error_rate}%"
    log "Max P99 latency: ${max_latency}ms"
    log "Health check failures: $health_checks_failed"
    
    # Decision
    if [ "$health_checks_failed" -eq 0 ] && (( $(echo "$max_error_rate <= $ERROR_THRESHOLD" | bc -l) )); then
        pass "Canary PASSED — Safe to promote"
        return 0
    else
        fail "Canary FAILED — Do not promote"
        return 1
    fi
}

monitor_canary "$@"
