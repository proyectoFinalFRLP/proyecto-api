// Configuración común de las pruebas de carga (TESIS-96).
//
// Todo sale de variables de entorno de k6 (`-e CLAVE=valor`) con defaults que
// apuntan a una API LOCAL. Para apuntar a otro entorno hay que decirlo
// explícitamente con BASE_URL, y para uno que no sea localhost además con
// ALLOW_REMOTE=1: es un freno contra martillar el despliegue por accidente
// (ver load/README.md).

import { fail } from 'k6';

export const BASE_URL = (__ENV.BASE_URL || 'http://localhost:3000').replace(/\/$/, '');

// `[::1]` también es local: en Windows Puma escucha en `[::]`, que no siempre
// acepta IPv4, y `localhost` puede resolver a 127.0.0.1 desde k6.
const LOCAL = /^https?:\/\/(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$/;
if (!LOCAL.test(BASE_URL) && __ENV.ALLOW_REMOTE !== '1') {
  fail(`BASE_URL=${BASE_URL} no es local. Para correr contra otro entorno, con el OK del ` +
       'equipo, agregá -e ALLOW_REMOTE=1 (ver load/README.md).');
}

// Datos que genera load/fixtures.rb (ids de productos, depósito, integración
// del webhook y su secreto). `open` sólo existe en el contexto de init.
const FIXTURES_PATH = __ENV.FIXTURES || '../fixtures.json';
export const FIXTURES = JSON.parse(open(FIXTURES_PATH));

export const EMAIL = __ENV.LOAD_EMAIL || FIXTURES.email;
export const PASSWORD = __ENV.LOAD_PASSWORD || 'password123';
export const SLUG = __ENV.LOAD_SLUG || FIXTURES.slug;

// El umbral de la card: p95 < 500 ms. Se puede endurecer o aflojar por corrida.
export const P95_MS = Number(__ENV.P95_MS || 500);

// Multiplicador de duración: SCALE=0.2 hace una corrida de humo de un quinto
// de la duración nominal, útil para validar el script antes de la corrida real.
export const SCALE = Number(__ENV.SCALE || 1);

export function seconds(nominal) {
  return `${Math.max(5, Math.round(nominal * SCALE))}s`;
}
