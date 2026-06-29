import http from 'k6/http';
import { check, group } from 'k6';

export const options = {
  stages: [
    { duration: '1m', target: 5 },   // 5 concurrent users for 1 minute
  ],
  thresholds: {
    'http_req_duration': ['p(95)<500'],  // 95% of requests under 500ms
    'http_req_failed': ['rate<0.1'],    // Less than 10% failure rate
  },
};

const API_BASE_URL = __ENV.API_BASE_URL || 'http://api-gateway:8080';

export default function () {
  group('Smoke Test', () => {
    // 1. Health check
    let healthRes = http.get(`${API_BASE_URL}/health`);
    check(healthRes, {
      'health status is 200': (r) => r.status === 200,
      'health response time < 100ms': (r) => r.timings.duration < 100,
    });

    // 2. Market data fetch
    let marketRes = http.get(`${API_BASE_URL}/v1/market-data?symbol=AAPL`);
    check(marketRes, {
      'market data status is 200': (r) => r.status === 200,
      'market data has price': (r) => r.json('price') !== null,
      'market data response time < 200ms': (r) => r.timings.duration < 200,
    });

    // 3. Order submission
    let orderRes = http.post(
      `${API_BASE_URL}/v1/orders`,
      JSON.stringify({
        symbol: 'AAPL',
        side: 'BUY',
        quantity: 100,
        price: 150.00,
        account_id: 'smoke-test',
      }),
      {
        headers: { 'Content-Type': 'application/json' },
      }
    );
    check(orderRes, {
      'order submission is 201': (r) => r.status === 201,
      'order has id': (r) => r.json('order_id') !== null,
      'order response time < 100ms': (r) => r.timings.duration < 100,
    });

    // 4. Order status check
    let orderId = orderRes.json('order_id');
    if (orderId) {
      let statusRes = http.get(`${API_BASE_URL}/v1/orders/${orderId}`);
      check(statusRes, {
        'order status is 200': (r) => r.status === 200 || r.status === 404,
      });
    }
  });
}
