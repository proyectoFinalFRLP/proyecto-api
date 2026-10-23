// Concurrencia de stock: 20 workers vendiendo el MISMO SKU a la vez (TESIS-96).
//
// Cada VU da de alta órdenes de 1 unidad del producto caliente (LOAD-HOT) sin
// pausa. El alta toma el advisory lock del producto con `wait: false`
// (Orders::CreateOrder, ADR-009): si otra orden del mismo producto está en
// vuelo, responde 409 al instante en vez de colgar un thread de Puma. Así que
// acá el 409 es una respuesta ESPERADA, no un error; lo que no puede aparecer
// es un 5xx ni otro código.
//
// La prueba de fondo es de consistencia, y la hace `teardown`: el stock final
// tiene que ser exactamente el inicial menos las órdenes que el sistema dice
// haber creado en esta corrida. Si el lock dejara pasar dos descuentos a la vez,
// faltarían o sobrarían unidades, y el threshold `stock_consistent` falla.
//
//   k6 run load/stock_contention.js

import http from 'k6/http';
import { check, fail } from 'k6';
import { Counter, Rate } from 'k6/metrics';
import { BASE_URL, FIXTURES, P95_MS, seconds } from './lib/config.js';
import { authHeaders, login } from './lib/api.js';
import { summaryFor, TREND_STATS } from './lib/summary.js';

const WORKERS = Number(__ENV.WORKERS || 20);
const NAME = 'POST /orders (mismo SKU)';

const created = new Counter('orders_created');
const conflicts = new Counter('orders_lock_conflict');
const unexpected = new Rate('unexpected_status');
const consistent = new Rate('stock_consistent');

http.setResponseCallback(http.expectedStatuses(200, 201, 409));

export const options = {
  scenarios: {
    same_sku: {
      executor: 'constant-vus',
      vus: WORKERS,
      duration: seconds(30),
    },
  },
  thresholds: {
    [`http_req_duration{name:${NAME}}`]: [`p(95)<${P95_MS}`],
    unexpected_status: ['rate==0'],
    orders_created: ['count>0'],
    stock_consistent: ['rate==1'],
  },
  summaryTrendStats: TREND_STATS,
};

function totalStock(token) {
  const res = http.get(`${BASE_URL}/api/v1/products/${FIXTURES.hot_product_id}`,
    { ...authHeaders(token), tags: { name: 'GET /products/:id (control)' } });
  if (res.status !== 200) fail(`no se pudo leer el producto caliente (${res.status})`);
  return res.json('total_stock');
}

export function setup() {
  const token = login();
  // Marca de la corrida en el nombre del cliente: después se cuentan las
  // órdenes de ESTA corrida con el buscador del listado.
  const run = `RUN${Date.now()}`;
  return { token, run, initial: totalStock(token) };
}

export default function ({ token, run }) {
  const body = {
    order: {
      customer_name: `${run} ${__VU}-${__ITER}`,
      requires_shipping: false,
      items: [{
        product_id: FIXTURES.hot_product_id,
        warehouse_id: FIXTURES.warehouse_id,
        quantity: 1,
        unit_price: 100,
      }],
    },
  };
  const res = http.post(`${BASE_URL}/api/v1/orders`, JSON.stringify(body),
    { ...authHeaders(token), tags: { name: NAME } });

  if (res.status === 201) created.add(1);
  if (res.status === 409) conflicts.add(1);
  unexpected.add(res.status !== 201 && res.status !== 409);
  check(res, { '201 o 409': (r) => r.status === 201 || r.status === 409 });
}

// Las métricas de k6 no se pueden leer desde teardown, así que las órdenes
// creadas se cuentan con la propia API: el buscador del listado por la marca de
// la corrida, leyendo sólo `meta.total`.
export function teardown({ token, run, initial }) {
  const final = totalStock(token);
  const res = http.get(`${BASE_URL}/api/v1/orders?search=${run}&per_page=1`,
    { ...authHeaders(token), tags: { name: 'GET /orders (control)' } });
  const orders = res.json('meta.total');
  const ok = initial - final === orders;
  consistent.add(ok);
  console.log(`stock inicial=${initial} final=${final} descontado=${initial - final} ` +
              `órdenes creadas=${orders} -> ${ok ? 'CONSISTENTE' : 'INCONSISTENTE'}`);
}

export const handleSummary = summaryFor('stock_contention');
