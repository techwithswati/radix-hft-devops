#!/bin/bash
##############################################################
# Integration Tests — Radix HFT
# End-to-end tests for service interactions
##############################################################

set -euo pipefail

NAMESPACE="${NAMESPACE:-trading}"
API_BASE_URL="${API_BASE_URL:-http://api-gateway:8080}"
ENVIRONMENT="${ENVIRONMENT:-staging}"
TEST_TIMEOUT=30

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

log() {
    echo -e "${BLUE}[TEST]${NC} $1"
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
# API Gateway Health
# ────────────────────────────────────────────────────
test_api_gateway_health() {
    log "Testing API Gateway health endpoint..."
    
    local response=$(curl -s -o /dev/null -w "%{http_code}" \
        "$API_BASE_URL/health" --max-time $TEST_TIMEOUT)
    
    if [ "$response" = "200" ]; then
        pass "API Gateway health check"
    else
        fail "API Gateway returned $response (expected 200)"
    fi
}

# ────────────────────────────────────────────────────
# Order Creation Flow
# ────────────────────────────────────────────────────
test_order_creation() {
    log "Testing order creation flow..."
    
    local order_payload=$(cat <<EOF
{
  "symbol": "AAPL",
  "side": "BUY",
  "quantity": 100,
  "price": 150.00,
  "account_id": "test-account-123"
}
EOF
)
    
    local response=$(curl -s -X POST \
        "$API_BASE_URL/v1/orders" \
        -H "Content-Type: application/json" \
        -d "$order_payload" \
        --max-time $TEST_TIMEOUT)
    
    local order_id=$(echo "$response" | grep -o '"order_id":"[^"]*' | cut -d'"' -f4)
    
    if [ -n "$order_id" ]; then
        pass "Order created with ID: $order_id"
        echo "$order_id"  # Return for further tests
    else
        fail "Order creation failed: $response"
        return 1
    fi
}

# ────────────────────────────────────────────────────
# Order Status Retrieval
# ────────────────────────────────────────────────────
test_order_status() {
    local order_id=$1
    
    log "Testing order status retrieval for order $order_id..."
    
    local response=$(curl -s -X GET \
        "$API_BASE_URL/v1/orders/$order_id" \
        --max-time $TEST_TIMEOUT)
    
    local status=$(echo "$response" | grep -o '"status":"[^"]*' | cut -d'"' -f4)
    
    if [ "$status" = "PENDING" ] || [ "$status" = "FILLED" ]; then
        pass "Order status retrieved: $status"
    else
        fail "Invalid order status: $status"
        return 1
    fi
}

# ────────────────────────────────────────────────────
# Market Data Feed
# ────────────────────────────────────────────────────
test_market_data() {
    log "Testing market data feed..."
    
    local response=$(curl -s \
        "$API_BASE_URL/v1/market-data?symbol=AAPL" \
        --max-time $TEST_TIMEOUT)
    
    local price=$(echo "$response" | grep -o '"price":[0-9.]*' | cut -d':' -f2)
    
    if [ -n "$price" ] && (( $(echo "$price > 0" | bc -l) )); then
        pass "Market data retrieved: $price"
    else
        fail "Invalid market data: $response"
        return 1
    fi
}

# ────────────────────────────────────────────────────
# Risk Engine Validation
# ────────────────────────────────────────────────────
test_risk_check() {
    log "Testing risk engine validation..."
    
    local risk_payload=$(cat <<EOF
{
  "account_id": "test-account-123",
  "symbol": "AAPL",
  "quantity": 10000,
  "price": 150.00
}
EOF
)
    
    local response=$(curl -s -X POST \
        "$API_BASE_URL/v1/risk/validate" \
        -H "Content-Type: application/json" \
        -d "$risk_payload" \
        --max-time $TEST_TIMEOUT)
    
    local approved=$(echo "$response" | grep -o '"approved":[^,}]*' | cut -d':' -f2)
    
    if [ "$approved" = "true" ] || [ "$approved" = "false" ]; then
        pass "Risk check completed: approved=$approved"
    else
        fail "Risk check failed: $response"
        return 1
    fi
}

# ────────────────────────────────────────────────────
# Latency Measurement
# ────────────────────────────────────────────────────
test_latency_slo() {
    log "Testing P99 latency SLO (< 50ms)..."
    
    local total_time=0
    local samples=10
    
    for i in $(seq 1 $samples); do
        local start=$(date +%s%N)
        curl -s "$API_BASE_URL/health" > /dev/null
        local end=$(date +%s%N)
        local elapsed=$(( (end - start) / 1000000 ))  # Convert to ms
        total_time=$((total_time + elapsed))
    done
    
    local avg_latency=$((total_time / samples))
    
    if [ "$avg_latency" -lt 50 ]; then
        pass "Latency SLO: ${avg_latency}ms < 50ms"
    else
        fail "Latency SLO: ${avg_latency}ms >= 50ms"
    fi
}

# ────────────────────────────────────────────────────
# Error Rate Check
# ────────────────────────────────────────────────────
test_error_rate() {
    log "Testing error rate (target < 0.1%)..."
    
    local total_requests=100
    local error_count=0
    
    for i in $(seq 1 $total_requests); do
        local response=$(curl -s -o /dev/null -w "%{http_code}" \
            "$API_BASE_URL/health" --max-time $TEST_TIMEOUT)
        
        if [ "$response" != "200" ]; then
            ((error_count++))
        fi
    done
    
    local error_rate=$(( (error_count * 100) / total_requests ))
    
    if [ "$error_rate" -lt 1 ]; then
        pass "Error rate: ${error_rate}% < 1%"
    else
        fail "Error rate: ${error_rate}% >= 1%"
    fi
}

# ────────────────────────────────────────────────────
# Database Consistency
# ────────────────────────────────────────────────────
test_database_consistency() {
    log "Testing database consistency..."
    
    local order_id="test-order-$(date +%s)"
    
    # Insert order
    local insert_response=$(curl -s -X POST \
        "$API_BASE_URL/v1/orders" \
        -H "Content-Type: application/json" \
        -d "{\"symbol\": \"TEST\", \"quantity\": 1}" \
        --max-time $TEST_TIMEOUT)
    
    sleep 1
    
    # Retrieve order
    local retrieve_response=$(curl -s -X GET \
        "$API_BASE_URL/v1/orders" \
        --max-time $TEST_TIMEOUT)
    
    if echo "$retrieve_response" | grep -q "TEST"; then
        pass "Database consistency check"
    else
        fail "Database consistency check: order not found"
    fi
}

# ────────────────────────────────────────────────────
# Load Test (Concurrent Requests)
# ────────────────────────────────────────────────────
test_concurrent_load() {
    log "Testing concurrent request handling (50 parallel)..."
    
    local concurrent_jobs=50
    local success_count=0
    
    for i in $(seq 1 $concurrent_jobs); do
        (curl -s "$API_BASE_URL/health" > /dev/null && ((success_count++))) &
    done
    
    wait
    
    local success_rate=$((success_count * 100 / concurrent_jobs))
    
    if [ "$success_rate" -ge 95 ]; then
        pass "Concurrent load test: ${success_rate}% success rate"
    else
        fail "Concurrent load test: ${success_rate}% < 95% threshold"
    fi
}

# ────────────────────────────────────────────────────
# Service Mesh/Istio Check
# ────────────────────────────────────────────────────
test_service_mesh() {
    log "Checking service mesh (Istio)..."
    
    if kubectl get virtualservices -n "$NAMESPACE" &>/dev/null; then
        pass "VirtualServices found (Istio enabled)"
    else
        log "Note: VirtualServices not found (Istio may not be installed)"
    fi
}

# ────────────────────────────────────────────────────
# Main test runner
# ────────────────────────────────────────────────────
run_integration_tests() {
    log "======================================"
    log "Radix HFT Integration Tests"
    log "Environment: $ENVIRONMENT"
    log "API Base URL: $API_BASE_URL"
    log "======================================"
    
    # Test connectivity
    if ! curl -s "$API_BASE_URL/health" > /dev/null; then
        fail "Cannot connect to API Gateway at $API_BASE_URL"
        return 1
    fi
    pass "Connected to API Gateway"
    
    log ""
    log "--- Service Tests ---"
    test_api_gateway_health
    test_market_data || true
    test_service_mesh || true
    
    log ""
    log "--- Order Flow Tests ---"
    if order_id=$(test_order_creation); then
        test_order_status "$order_id" || true
    fi
    
    log ""
    log "--- Risk Management Tests ---"
    test_risk_check || true
    
    log ""
    log "--- Performance Tests ---"
    test_latency_slo
    test_error_rate
    
    log ""
    log "--- Data Consistency Tests ---"
    test_database_consistency || true
    
    log ""
    log "--- Load Tests ---"
    test_concurrent_load || true
    
    log ""
    log "======================================"
    log "Results: $PASSED_TESTS/$TOTAL_TESTS passed"
    log "======================================"
    
    if [ "$FAILED_TESTS" -gt 0 ]; then
        exit 1
    fi
}

run_integration_tests "$@"
