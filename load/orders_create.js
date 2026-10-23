// Alta de órdenes manuales: POST /api/v1/orders a 50 req/s sostenidos (TESIS-96).
//
// Cada orden lleva una línea de 1 unidad de uno de los productos que crea
// load/fixtures.rb (200 por default, con stock de sobra), en ronda: la orden N
// usa el producto N mod 200. Repartir es deliberado: el alta toma el lock del
// producto SIN esperar (`wait: false`, ADR-009) y responde 409 si otra orden
// del mismo producto está en vuelo. Con productos al azar dos requests
// simultáneos caen a veces en el mismo y el 409 ensucia la tasa de error; en
// ronda, para chocar tendrían que estar 200 órdenes en vuelo a la vez.
// Concentrar todo en un SKU mide la contención y no el alta: eso lo hace
// stock_contention.js.
//
//   k6 run -e LOAD_PASSWORD=... load/orders_create.js

import http from 'k6/http';
import { check } from 'k6';
import { BASE_URL, FIXTURES, P95_MS, seconds } from './lib/config.js';
import exec from 'k6/execution';
import { authHeaders, login } from './lib/api.js';
import { summaryFor, TREND_STATS } from './lib/summary.js';

const RATE = Number(__ENV.RATE || 50);

export const options = {
  scenarios: {
    create_orders: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: seconds(60),
      preAllocatedVUs: RATE * 2,
      maxVUs: RATE * 6,
    },
  },
  thresholds: {
    'http_req_duration{name:POST /orders}': [`p(95)<${P95_MS}`],
    'http_req_failed{name:POST /orders}': ['rate<0.01'],
    // Si k6 no llega a despachar la tasa pedida (VUs agotados porque el
    // servidor no da abasto), la corrida no cumple el objetivo aunque las
    // latencias de lo que sí salió se vean bien.
    dropped_iterations: ['count<1'],
  },
  summaryTrendStats: TREND_STATS,
};

export function setup() {
  return { token: login() };
}

export default function ({ token }) {
  const body = {
    order: {
      customer_name: `Carga ${__VU}-${__ITER}`,
      customer_address: 'Calle 7 1234',
      customer_zip_code: '1900',
      customer_city: 'La Plata',
      customer_province: 'Buenos Aires',
      requires_shipping: false,
      items: [{
        product_id: FIXTURES.product_ids[exec.scenario.iterationInTest % FIXTURES.product_ids.length],
        warehouse_id: FIXTURES.warehouse_id,
        quantity: 1,
        unit_price: 100,
      }],
    },
  };
  const res = http.post(`${BASE_URL}/api/v1/orders`, JSON.stringify(body),
    { ...authHeaders(token), tags: { name: 'POST /orders' } });
  check(res, { 'POST /orders 201': (r) => r.status === 201 });
}

export const handleSummary = summaryFor('orders_create');
