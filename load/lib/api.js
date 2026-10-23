// Helpers HTTP compartidos por los escenarios.

import http from 'k6/http';
import { check, fail } from 'k6';
import { BASE_URL, EMAIL, PASSWORD, SLUG } from './config.js';

// Login UNA vez por corrida, desde `setup()`. El token (24 h de vida) se
// reparte a todos los VUs. Pedir un token por iteración mediría bcrypt en vez
// del endpoint bajo prueba, y un error de credenciales repetido choca contra el
// límite de 10 intentos fallidos por IP cada 3 minutos (FailedAttemptLimit).
export function login() {
  const res = http.post(
    `${BASE_URL}/api/v1/auth/login`,
    JSON.stringify({ email: EMAIL, password: PASSWORD }),
    { headers: { 'Content-Type': 'application/json', 'X-Tenant-Slug': SLUG },
      tags: { name: 'POST /auth/login (setup)' } },
  );
  if (res.status !== 200) {
    fail(`login falló (${res.status}): ${res.body}. ¿Corriste load/fixtures.rb y ` +
         'LOAD_PASSWORD es el de los seeds?');
  }
  return res.json('token');
}

export function authHeaders(token, extra = {}) {
  return {
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
      Accept: 'application/json',
      ...extra,
    },
  };
}

export function get(token, path, name) {
  const res = http.get(`${BASE_URL}${path}`, { ...authHeaders(token), tags: { name } });
  check(res, { [`${name} 200`]: (r) => r.status === 200 });
  return res;
}

export function pick(list) {
  return list[Math.floor(Math.random() * list.length)];
}
