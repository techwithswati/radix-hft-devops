import http from 'k6/http';
import { check, group, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

// Custom metrics
const errorRate = new Rate('errors');
const orderLatency = new Trend('order_latency', { unit: 'ms' });
const marketDataLatency = new Trend('market_data_latency', { unit: 'ms' });
const throughput = new Rate('successful_orders');

export const options = {
  stages: [
    { duration: '30s', target: 10 },    // Ramp up to 10 users
    { duration: '1m', target: 50 },     // Ramp up to 50 users
    { duration: '3m', target: 100 },    // Peak load at 100 users
    { duration: '1m', target: 50 },     // Ramp down to 50 users
    { duration: '30s', target: 0 },     // Ramp down to 0 users
  ],
  thresholds: {
    // Error rate must stay below 1%
    'errors': ['rate<0.01'],
    // P95 latency must be under 50ms
    'order_latency': ['p(95)<50', 'p(99)<100'],
    'market_data_latency': ['p(95)<10', 'p(99)<20'],
    // Success rate must be above 99%
    'successful_orders': ['rate>0.99'],
    // HTTP requests must succeed 99%+ of the time
    'http_req_duration': ['p(95)<50', 'p(99)<100'],
  },
};

const API_BASE_URL = __ENV.API_BASE_URL || 'http://api-gateway:8080';

export default function () {
  // ────────────────────────────────────────────────────
  // Health check
  // ────────────────────────────────────────────────────
  group('Health Check', () => {
    const response = http.get(`${API_BASE_URL}/health`);
    check(response, {
      'status is 200': (r) => r.status === 200,
      'response time < 10ms': (r) => r.timings.duration < 10,
    });
  });

  sleep(1);

  // ────────────────────────────────────────────────────
  // Market Data Retrieval
  // ────────────────────────────────────────────────────
  group('Fetch Market Data', () => {
    const symbols = ['AAPL', 'MSFT', 'GOOG', 'AMZN', 'NVDA'];
    const symbol = symbols[Math.floor(Math.random() * symbols.length)];

    const start = Date.now();
    const response = http.get(`${API_BASE_URL}/v1/market-data?symbol=${symbol}`);
    const duration = Date.now() - start;

    marketDataLatency.add(duration);

    check(response, {
      'status is 200': (r) => r.status === 200,
      'price exists': (r) => r.json('price') !== undefined,
      'bid-ask spread valid': (r) => {
        const bid = r.json('bid');
        const ask = r.json('ask');
        return bid > 0 && ask > bid;
      },
    });

    if (response.status !== 200) {
      errorRate.add(1);
    }
  });

  sleep(0.5);

  // ────────────────────────────────────────────────────
  // Order Creation (Happy Path)
  // ────────────────────────────────────────────────────
  group('Create Order', () => {
    const orderPayload = {
      symbol: ['AAPL', 'MSFT', 'GOOG'][Math.floor(Math.random() * 3)],
      side: Math.random() > 0.5 ? 'BUY' : 'SELL',
      quantity: Math.floor(Math.random() * 1000) + 10,
      price: (Math.random() * 100 + 100).toFixed(2),
      account_id: `account-${__VU}-${__ITER}`,
    };

    const start = Date.now();
    const response = http.post(
      `${API_BASE_URL}/v1/orders`,
      JSON.stringify(orderPayload),
      {
        headers: { 'Content-Type': 'application/json' },
      }
    );
    const duration = Date.now() - start;

    orderLatency.add(duration);

    const success = check(response, {
      'order created': (r) => r.status === 201,
      'order_id exists': (r) => r.json('order_id') !== undefined,
      'status is PENDING': (r) => r.json('status') === 'PENDING',
      'latency < 50ms': (r) => r.timings.duration < 50,
    });

    if (success) {
      throughput.add(1);
    } else {
      errorRate.add(1);
    }
  });

  sleep(1);

  // ────────────────────────────────────────────────────
  // Order Status Check
  // ────────────────────────────────────────────────────
  group('Check Order Status', () => {
    const orderId = `order-${__VU}-${Math.floor(__ITER / 2)}`;

    const response = http.get(`${API_BASE_URL}/v1/orders/${orderId}`);

    check(response, {
      'response received': (r) => r.status === 200 || r.status === 404,
      'valid order status': (r) => {
        const status = r.json('status');
        return ['PENDING', 'FILLED', 'REJECTED', 'CANCELLED'].includes(status);
      },
    });
  });

  sleep(0.5);

  // ────────────────────────────────────────────────────
  // Risk Engine Validation
  // ────────────────────────────────────────────────────
  group('Risk Check', () => {
    const riskPayload = {
      account_id: `account-${__VU}`,
      symbol: 'AAPL',
      quantity: Math.floor(Math.random() * 5000) + 100,
      price: 150.0,
    };

    const response = http.post(
      `${API_BASE_URL}/v1/risk/validate`,
      JSON.stringify(riskPayload),
      {
        headers: { 'Content-Type': 'application/json' },
      }
    );

    check(response, {
      'risk check completed': (r) => r.status === 200,
      'approved field exists': (r) => r.json('approved') !== undefined,
      'latency < 5ms': (r) => r.timings.duration < 5,
    });

    if (response.status !== 200) {
      errorRate.add(1);
    }
  });

  sleep(1);

  // ────────────────────────────────────────────────────
  // Cancel Order
  // ────────────────────────────────────────────────────
  group('Cancel Order', () => {
    const orderId = `order-${__VU}-${Math.floor(__ITER / 3)}`;

    const response = http.del(
      `${API_BASE_URL}/v1/orders/${orderId}`,
      {
        headers: { 'Content-Type': 'application/json' },
      }
    );

    check(response, {
      'order deleted or not found': (r) =>
        r.status === 204 || r.status === 404,
    });
  });

  sleep(2);

  // ────────────────────────────────────────────────────
  // Get Account Summary
  // ────────────────────────────────────────────────────
  group('Account Summary', () => {
    const accountId = `account-${__VU}`;

    const response = http.get(`${API_BASE_URL}/v1/accounts/${accountId}`);

    check(response, {
      'account exists': (r) => r.status === 200 || r.status === 404,
      'balance exists': (r) => r.json('balance') !== undefined,
      'positions array exists': (r) => Array.isArray(r.json('positions')),
    });
  });

  sleep(1);
}

// ────────────────────────────────────────────────────
// Setup (runs once at start)
// ────────────────────────────────────────────────────
export function setup() {
  const response = http.get(`${API_BASE_URL}/health`);
  if (response.status !== 200) {
    throw new Error(
      `API not responding: ${response.status}. URL: ${API_BASE_URL}`
    );
  }

  console.log(`✓ Load test setup complete. Target URL: ${API_BASE_URL}`);

  return { apiReady: true };
}

// ────────────────────────────────────────────────────
// Teardown (runs once at end)
// ────────────────────────────────────────────────────
export function teardown(data) {
  console.log('✓ Load test teardown complete');
}

// ────────────────────────────────────────────────────
// Custom summary
// ────────────────────────────────────────────────────
export function handleSummary(data) {
  return {
    stdout: textSummary(data, { indent: ' ', enableColors: true }),
    'results.json': data,
  };
}

// Text summary formatter
function textSummary(data, options) {
  let summary = '';

  // Custom metrics
  if (data.metrics.errors) {
    const errorRate = (data.metrics.errors.values.rate * 100).toFixed(2);
    summary += `\n📊 Error Rate: ${errorRate}%`;
  }

  if (data.metrics.order_latency) {
    const p95 = data.metrics.order_latency.values['p(95)'].toFixed(0);
    const p99 = data.metrics.order_latency.values['p(99)'].toFixed(0);
    summary += `\n⏱️  Order Latency: P95=${p95}ms, P99=${p99}ms`;
  }

  if (data.metrics.successful_orders) {
    const successRate = (data.metrics.successful_orders.values.rate * 100).toFixed(1);
    summary += `\n✅ Success Rate: ${successRate}%`;
  }

  return summary;
}
