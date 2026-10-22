// Lecturas de las pantallas principales (TESIS-96): listado de órdenes paginado
// —el de la card—, catálogo con búsqueda y listado de envíos, en paralelo y a
// tasa constante cada uno.
//
// El listado de órdenes recorre páginas al azar dentro de las primeras
// ORDER_PAGES (20 por página), con un tercio de los pedidos filtrando por estado
// y otro tercio buscando: son los tres caminos de la pantalla, y el buscador es
// un ILIKE sin índice (ver OrdersController#apply_search), el más caro.
//
//   k6 run load/listings.js

import { P95_MS, seconds } from './lib/config.js';
import { get, login, pick } from './lib/api.js';
import { summaryFor, TREND_STATS } from './lib/summary.js';

const ORDER_PAGES = Number(__ENV.ORDER_PAGES || 50);
const DURATION = seconds(60);

function rateScenario(exec, rate) {
  return {
    executor: 'constant-arrival-rate',
    exec,
    rate,
    timeUnit: '1s',
    duration: DURATION,
    preAllocatedVUs: rate * 2,
    maxVUs: rate * 6,
  };
}

export const options = {
  scenarios: {
    orders_list: rateScenario('ordersList', Number(__ENV.ORDERS_RATE || 30)),
    products_list: rateScenario('productsList', Number(__ENV.PRODUCTS_RATE || 10)),
    shipments_list: rateScenario('shipmentsList', Number(__ENV.SHIPMENTS_RATE || 10)),
  },
  thresholds: {
    'http_req_duration{name:GET /orders}': [`p(95)<${P95_MS}`],
    'http_req_duration{name:GET /orders?search}': [`p(95)<${P95_MS}`],
    'http_req_duration{name:GET /products}': [`p(95)<${P95_MS}`],
    'http_req_duration{name:GET /shipments}': [`p(95)<${P95_MS}`],
    http_req_failed: ['rate<0.01'],
    dropped_iterations: ['count<1'],
  },
  summaryTrendStats: TREND_STATS,
};

export function setup() {
  return { token: login() };
}

const STATUSES = ['pending', 'paid', 'cancelled'];
const TERMS = ['perez', 'gomez', 'calle 1', '1900', 'diaz'];

export function ordersList({ token }) {
  const page = 1 + Math.floor(Math.random() * ORDER_PAGES);
  const roll = Math.random();
  if (roll < 1 / 3) {
    get(token, `/api/v1/orders?page=${page}&per_page=20`, 'GET /orders');
  } else if (roll < 2 / 3) {
    get(token, `/api/v1/orders?page=${page}&per_page=20&status=${pick(STATUSES)}`,
      'GET /orders');
  } else {
    get(token, `/api/v1/orders?per_page=20&search=${encodeURIComponent(pick(TERMS))}`,
      'GET /orders?search');
  }
}

export function productsList({ token }) {
  const search = Math.random() < 0.5 ? `&search=${encodeURIComponent('carga 1')}` : '';
  get(token, `/api/v1/products?page=${1 + Math.floor(Math.random() * 5)}&per_page=20${search}`,
    'GET /products');
}

export function shipmentsList({ token }) {
  get(token, '/api/v1/shipments?page=1&per_page=20', 'GET /shipments');
}

export const handleSummary = summaryFor('listings');

