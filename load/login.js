// Login: POST /api/v1/auth/login con credenciales válidas (TESIS-96).
//
// A tasa baja a propósito. Cada login exitoso es un bcrypt (cost 12 en
// producción): es CPU pura por diseño, y la tasa realista es la de operadores
// abriendo sesión, no cientos por segundo. Los logins exitosos no tienen tope;
// los FALLIDOS sí: 10 por IP cada 3 minutos (FailedAttemptLimit), así que este
// script no prueba credenciales malas. Un LOAD_PASSWORD equivocado se corta en
// el primer request (ver lib/api.js) en vez de quemar el cupo.
//
//   k6 run load/login.js

import http from 'k6/http';
import { check } from 'k6';
import { BASE_URL, EMAIL, P95_MS, PASSWORD, SLUG, seconds } from './lib/config.js';
import { login } from './lib/api.js';
import { summaryFor, TREND_STATS } from './lib/summary.js';

const RATE = Number(__ENV.RATE || 5);
const NAME = 'POST /auth/login';

export const options = {
  scenarios: {
    login: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: seconds(30),
      preAllocatedVUs: RATE * 4,
      maxVUs: RATE * 20,
    },
  },
  thresholds: {
    [`http_req_duration{name:${NAME}}`]: [`p(95)<${P95_MS}`],
    [`http_req_failed{name:${NAME}}`]: ['rate<0.01'],
    dropped_iterations: ['count<1'],
  },
  summaryTrendStats: TREND_STATS,
};

// Un login de prueba antes de arrancar: si las credenciales están mal, corta
// acá con un único intento fallido.
export function setup() {
  login();
}

export default function () {
  const res = http.post(
    `${BASE_URL}/api/v1/auth/login`,
    JSON.stringify({ email: EMAIL, password: PASSWORD }),
    { headers: { 'Content-Type': 'application/json', 'X-Tenant-Slug': SLUG },
      tags: { name: NAME } },
  );
  check(res, { 'login 200': (r) => r.status === 200 });
}

export const handleSummary = summaryFor('login');
