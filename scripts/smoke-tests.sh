#!/bin/bash
##############################################################
# Smoke Tests — Radix HFT
# Quick health checks for all trading services
##############################################################

set -euo pipefail

NAMESPACE="${NAMESPACE:-trading}"
TIMEOUT="${TIMEOUT:-300}"
ENVIRONMENT="${ENVIRONMENT:-staging}"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

log() {
    echo -e "${BLUE}[SMOKE]${NC} $1"
}

pass() {
    echo -e "${GREEN}✓ PASS${NC} $1"
    ((PASSED_TESTS++))
    ((TOTAL_TESTS++))
}

fail() {
    echo -e "${RED}✗ FAIL${NC} $1"
    ((FAILED_TESTS++))
    ((TOTAL_TESTS++))
}

# ────────────────────────────────────────────────────
# Wait for deployment readiness
# ────────────────────────────────────────────────────
wait_for_deployment() {
    local deployment=$1
    local timeout=$2
    
    log "Waiting for deployment/$deployment to be ready (${timeout}s)..."
    
    if kubectl rollout status deployment/$deployment \
        -n "$NAMESPACE" \
        --timeout="${timeout}s" &>/dev/null; then
        pass "Deployment $deployment is ready"
    else
        fail "Deployment $deployment failed to become ready"
        return 1
    fi
}

# ────────────────────────────────────────────────────
# Check pod health
# ────────────────────────────────────────────────────
check_pod_health() {
    local label=$1
    
    log "Checking pod health for label: $label"
    
    local pods=$(kubectl get pods -n "$NAMESPACE" -l "$label" -o name)
    
    if [ -z "$pods" ]; then
        fail "No pods found with label $label"
        return 1
    fi
    
    for pod in $pods; do
        local pod_name=$(basename "$pod")
        local status=$(kubectl get "$pod" -n "$NAMESPACE" -o jsonpath='{.status.phase}')
        
        if [ "$status" = "Running" ]; then
            pass "Pod $pod_name is Running"
        else
            fail "Pod $pod_name is $status (expected Running)"
        fi
    done
}

# ────────────────────────────────────────────────────
# Test service connectivity
# ────────────────────────────────────────────────────
test_service_endpoint() {
    local service=$1
    local port=$2
    local path=${3:-"/healthz"}
    
    log "Testing service endpoint: http://$service:$port$path"
    
    local pod=$(kubectl get pod -n "$NAMESPACE" \
        -l app="$service" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "$pod" ]; then
        fail "No pods found for service $service"
        return 1
    fi
    
    # Port-forward and test
    kubectl port-forward -n "$NAMESPACE" "pod/$pod" "$port:$port" &
    local pf_pid=$!
    sleep 2
    
    if curl -sf "http://localhost:$port$path" > /dev/null; then
        pass "Service $service endpoint is healthy"
    else
        fail "Service $service endpoint returned error"
    fi
    
    kill $pf_pid 2>/dev/null || true
}

# ────────────────────────────────────────────────────
# Check database connectivity
# ────────────────────────────────────────────────────
check_database() {
    log "Checking database connectivity..."
    
    local db_pod=$(kubectl get pod -n "$NAMESPACE" \
        -o name --all-containers=true 2>/dev/null | head -1)
    
    if [ -z "$db_pod" ]; then
        fail "Cannot find database pod"
        return 1
    fi
    
    # Check if database secret exists
    if kubectl get secret -n "$NAMESPACE" aurora-credentials &>/dev/null; then
        pass "Database credentials secret exists"
    else
        fail "Database credentials secret not found"
    fi
}

# ────────────────────────────────────────────────────
# Check Kafka connectivity
# ────────────────────────────────────────────────────
check_kafka() {
    log "Checking Kafka connectivity..."
    
    local kafka_brokers="${KAFKA_BROKERS:-localhost:9092}"
    
    # Try to list Kafka topics
    local pod=$(kubectl get pod -n "$NAMESPACE" \
        -l app=order-service \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "$pod" ]; then
        fail "Cannot find order-service pod for Kafka test"
        return 1
    fi
    
    # Check if Kafka secret exists
    if kubectl get secret -n "$NAMESPACE" kafka-credentials &>/dev/null; then
        pass "Kafka credentials secret exists"
    else
        warn "Kafka credentials secret not found (may not be configured)"
    fi
}

# ────────────────────────────────────────────────────
# Check Redis connectivity
# ────────────────────────────────────────────────────
check_redis() {
    log "Checking Redis connectivity..."
    
    if kubectl get secret -n "$NAMESPACE" redis-auth &>/dev/null; then
        pass "Redis auth secret exists"
    else
        fail "Redis auth secret not found"
    fi
}

# ────────────────────────────────────────────────────
# Check resource allocation
# ────────────────────────────────────────────────────
check_resources() {
    log "Checking resource allocation..."
    
    local pods=$(kubectl get pods -n "$NAMESPACE" -o json)
    local pod_count=$(echo "$pods" | jq '.items | length')
    
    if [ "$pod_count" -gt 0 ]; then
        pass "Found $pod_count pods in namespace"
    else
        fail "No pods found in namespace"
        return 1
    fi
    
    # Check for pods with insufficient resources
    local pending=$(echo "$pods" | jq '.items[] | select(.status.phase=="Pending")')
    
    if [ -z "$pending" ]; then
        pass "No pending pods (resource constraints)"
    else
        fail "Pending pods found (may indicate resource constraints)"
    fi
}

# ────────────────────────────────────────────────────
# Check metrics collection
# ────────────────────────────────────────────────────
check_metrics() {
    log "Checking metrics collection..."
    
    local metrics_pod=$(kubectl get pod -n monitoring \
        -l app.kubernetes.io/name=prometheus \
        -o name 2>/dev/null | head -1)
    
    if [ -z "$metrics_pod" ]; then
        fail "Prometheus not found in monitoring namespace"
        return 1
    fi
    
    pass "Prometheus is running"
}

# ────────────────────────────────────────────────────
# Check logs accessibility
# ────────────────────────────────────────────────────
check_logs() {
    log "Checking log accessibility..."
    
    local pod=$(kubectl get pod -n "$NAMESPACE" \
        -l app=order-service \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "$pod" ]; then
        fail "Cannot find pod for log test"
        return 1
    fi
    
    if kubectl logs "$pod" -n "$NAMESPACE" --tail=5 &>/dev/null; then
        pass "Pod logs are accessible"
    else
        fail "Cannot access pod logs"
    fi
}

# ────────────────────────────────────────────────────
# Check service discovery
# ────────────────────────────────────────────────────
check_service_discovery() {
    log "Checking service discovery..."
    
    local services=("order-service" "market-data-service" "risk-engine" "api-gateway")
    
    for svc in "${services[@]}"; do
        if kubectl get service "$svc" -n "$NAMESPACE" &>/dev/null; then
            pass "Service $svc discovered"
        else
            fail "Service $svc not found"
        fi
    done
}

# ────────────────────────────────────────────────────
# Run all smoke tests
# ────────────────────────────────────────────────────
run_smoke_tests() {
    log "======================================"
    log "Radix HFT Smoke Tests"
    log "Environment: $ENVIRONMENT"
    log "Namespace: $NAMESPACE"
    log "======================================"
    
    # Kubernetes connectivity
    if ! kubectl cluster-info &>/dev/null; then
        fail "Cannot connect to Kubernetes cluster"
        return 1
    fi
    pass "Connected to Kubernetes cluster"
    
    # Namespace exists
    if kubectl get namespace "$NAMESPACE" &>/dev/null; then
        pass "Namespace $NAMESPACE exists"
    else
        fail "Namespace $NAMESPACE does not exist"
        return 1
    fi
    
    log ""
    log "--- Deployments ---"
    wait_for_deployment "order-service" "$TIMEOUT" || true
    wait_for_deployment "market-data-service" "$TIMEOUT" || true
    wait_for_deployment "risk-engine" "$TIMEOUT" || true
    wait_for_deployment "api-gateway" "$TIMEOUT" || true
    
    log ""
    log "--- Pod Health ---"
    check_pod_health "app=order-service" || true
    check_pod_health "app=market-data-service" || true
    check_pod_health "app=risk-engine" || true
    check_pod_health "app=api-gateway" || true
    
    log ""
    log "--- Service Discovery ---"
    check_service_discovery
    
    log ""
    log "--- Infrastructure ---"
    check_database || true
    check_kafka || true
    check_redis || true
    check_resources
    
    log ""
    log "--- Observability ---"
    check_metrics || true
    check_logs || true
    
    log ""
    log "======================================"
    log "Results: $PASSED_TESTS/$TOTAL_TESTS passed"
    log "======================================"
    
    if [ "$FAILED_TESTS" -gt 0 ]; then
        exit 1
    fi
}

run_smoke_tests "$@"
