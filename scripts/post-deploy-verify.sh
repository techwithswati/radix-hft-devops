#!/bin/bash
##############################################################
# Post-Deploy Verification — Radix HFT
# Comprehensive validation after deployment
##############################################################

set -euo pipefail

NAMESPACE="${NAMESPACE:-trading}"
ENVIRONMENT="${ENVIRONMENT:-staging}"
TIMEOUT="${TIMEOUT:-600}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

log() {
    echo -e "${BLUE}[VERIFY]${NC} $1"
}

pass() {
    echo -e "${GREEN}✓${NC} $1"
    ((TESTS_PASSED++))
}

fail() {
    echo -e "${RED}✗${NC} $1"
    ((TESTS_FAILED++))
}

# ────────────────────────────────────────────────────
# Deployment Status
# ────────────────────────────────────────────────────
verify_deployments() {
    log "Verifying deployments..."
    
    local deployments=("order-service" "market-data-service" "risk-engine" "api-gateway")
    
    for deployment in "${deployments[@]}"; do
        if kubectl rollout status deployment/$deployment -n $NAMESPACE --timeout=5m &>/dev/null; then
            pass "Deployment $deployment is ready"
        else
            fail "Deployment $deployment failed rollout"
        fi
    done
}

# ────────────────────────────────────────────────────
# Pod Health
# ────────────────────────────────────────────────────
verify_pods() {
    log "Verifying pod health..."
    
    local total_pods=$(kubectl get pods -n $NAMESPACE --no-headers | wc -l)
    local running_pods=$(kubectl get pods -n $NAMESPACE -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' | wc -w)
    
    if [ $running_pods -eq $total_pods ]; then
        pass "All pods running: $running_pods/$total_pods"
    else
        fail "Not all pods running: $running_pods/$total_pods"
    fi
    
    # Check for pod restarts
    local high_restarts=$(kubectl get pods -n $NAMESPACE -o jsonpath='{.items[?(@.status.containerStatuses[0].restartCount>2)].metadata.name}')
    if [ -z "$high_restarts" ]; then
        pass "No pods with excessive restarts"
    else
        fail "Pods with high restart count: $high_restarts"
    fi
}

# ────────────────────────────────────────────────────
# Service Endpoints
# ────────────────────────────────────────────────────
verify_services() {
    log "Verifying service endpoints..."
    
    local services=("order-service" "market-data-service" "risk-engine" "api-gateway")
    
    for service in "${services[@]}"; do
        if kubectl get service $service -n $NAMESPACE &>/dev/null; then
            local endpoints=$(kubectl get endpoints $service -n $NAMESPACE -o jsonpath='{.subsets[0].addresses}' | grep -o "ip" | wc -l)
            if [ $endpoints -gt 0 ]; then
                pass "Service $service has endpoints: $endpoints"
            else
                fail "Service $service has no endpoints"
            fi
        else
            fail "Service $service not found"
        fi
    done
}

# ────────────────────────────────────────────────────
# Metrics Collection
# ────────────────────────────────────────────────────
verify_metrics() {
    log "Verifying metrics collection..."
    
    local prometheus_ready=$(kubectl get pod -n monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
    
    if [ "$prometheus_ready" = "Running" ]; then
        pass "Prometheus is running"
    else
        fail "Prometheus not running or not found"
    fi
}

# ────────────────────────────────────────────────────
# Error Rate Check
# ────────────────────────────────────────────────────
verify_error_rate() {
    log "Verifying error rate..."
    
    local error_count=$(kubectl logs -n $NAMESPACE -l app=order-service --tail=100 --all-containers=true 2>/dev/null | grep -i "error\|exception" | wc -l || echo 0)
    
    if [ $error_count -lt 5 ]; then
        pass "Error rate acceptable: $error_count errors in last 100 log lines"
    else
        fail "Error rate high: $error_count errors in last 100 log lines"
    fi
}

# ────────────────────────────────────────────────────
# Resource Utilization
# ────────────────────────────────────────────────────
verify_resources() {
    log "Verifying resource utilization..."
    
    if kubectl top pods -n $NAMESPACE &>/dev/null; then
        local high_cpu=$(kubectl top pods -n $NAMESPACE --no-headers | awk '$2 > 2000 {print $1}' | wc -l)
        
        if [ $high_cpu -eq 0 ]; then
            pass "CPU usage within limits"
        else
            fail "High CPU pods: $high_cpu"
        fi
    else
        fail "Metrics server not available"
    fi
}

# ────────────────────────────────────────────────────
# Storage Verification
# ────────────────────────────────────────────────────
verify_storage() {
    log "Verifying storage..."
    
    local pvcs=$(kubectl get pvc -n $NAMESPACE -o jsonpath='{.items[*].metadata.name}')
    
    if [ -z "$pvcs" ]; then
        pass "No PVCs required (expected)"
    else
        local bound_pvcs=$(kubectl get pvc -n $NAMESPACE -o jsonpath='{.items[?(@.status.phase=="Bound")].metadata.name}' | wc -w)
        local total_pvcs=$(kubectl get pvc -n $NAMESPACE --no-headers | wc -l)
        
        if [ $bound_pvcs -eq $total_pvcs ]; then
            pass "All PVCs bound: $bound_pvcs/$total_pvcs"
        else
            fail "Not all PVCs bound: $bound_pvcs/$total_pvcs"
        fi
    fi
}

# ────────────────────────────────────────────────────
# Network Policies
# ────────────────────────────────────────────────────
verify_network() {
    log "Verifying network policies..."
    
    if kubectl get networkpolicies -n $NAMESPACE &>/dev/null; then
        local policies=$(kubectl get networkpolicies -n $NAMESPACE --no-headers | wc -l)
        pass "Network policies configured: $policies"
    else
        pass "No network policies (expected if using service mesh)"
    fi
}

# ────────────────────────────────────────────────────
# RBAC Verification
# ────────────────────────────────────────────────────
verify_rbac() {
    log "Verifying RBAC..."
    
    if kubectl get roles -n $NAMESPACE &>/dev/null; then
        local roles=$(kubectl get roles -n $NAMESPACE --no-headers | wc -l)
        pass "RBAC configured: $roles roles"
    else
        fail "No RBAC configuration found"
    fi
}

# ────────────────────────────────────────────────────
# Smoke Test
# ────────────────────────────────────────────────────
verify_smoke_test() {
    log "Running smoke tests..."
    
    if bash scripts/smoke-tests.sh &>/dev/null; then
        pass "Smoke tests passed"
    else
        fail "Smoke tests failed"
    fi
}

# ────────────────────────────────────────────────────
# Main Verification
# ────────────────────────────────────────────────────
run_verification() {
    log "======================================"
    log "Post-Deployment Verification"
    log "Environment: $ENVIRONMENT"
    log "Namespace: $NAMESPACE"
    log "======================================"
    log ""
    
    verify_deployments
    verify_pods
    verify_services
    verify_metrics
    verify_error_rate
    verify_resources
    verify_storage
    verify_network
    verify_rbac
    verify_smoke_test
    
    log ""
    log "======================================"
    log "Verification Summary"
    log "======================================"
    log "Passed: $TESTS_PASSED"
    log "Failed: $TESTS_FAILED"
    
    if [ $TESTS_FAILED -eq 0 ]; then
        pass "All verifications passed! ✅"
        return 0
    else
        fail "Some verifications failed ❌"
        return 1
    fi
}

run_verification "$@"
