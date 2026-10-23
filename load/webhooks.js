// Ingesta de webhooks: POST /api/webhooks/integrations/:id a 100 req/s (TESIS-96).
//
// Cada evento es una venta de Shopify firmada con HMAC-SHA256 en base64 sobre el
// body crudo, con el secreto que load/fixtures.rb dejó en la integración: pasa
// por Webhooks::VerifySignature igual que un evento real.
//
// Lo que se mide es la LATENCIA DE ACEPTACIÓN: el gateway verifica la firma,
// persiste el WebhookLog, encola Orders::ProcessWebhookEventJob y responde 202
// (ADR-010). El procesamiento lo hacen los workers de Solid Queue, que no son
// parte del request; ver load/README.md sobre cómo medir el drenaje de la cola.
//
//   k6 run load/webhooks.js

import http from 'k6/http';
import crypto from 'k6/crypto';
import exec from 'k6/execution';
import { check } from 'k6';
import { BASE_URL, FIXTURES, P95_MS, seconds } from './lib/config.js';
import { summaryFor, TREND_STATS } from './lib/summary.js';

const RATE = Number(__ENV.RATE || 100);
const NAME = 'POST /webhooks/integrations/:id';

export const options = {
  scenarios: {
    webhook_burst: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: seconds(60),
      preAllocatedVUs: RATE * 2,
      maxVUs: RATE * 6,
    },
  },
  thresholds: {
    [`http_req_duration{name:${NAME}}`]: [`p(95)<${P95_MS}`],
    [`http_req_failed{name:${NAME}}`]: ['rate<0.01'],
    dropped_iterations: ['count<1'],
  },
  summaryTrendStats: TREND_STATS,
};

// Forma de un `orders/create` de Shopify, recortada a lo que lee la plantilla
// del servicio (response_mapper del seed de Shopify). El id es único por
// iteración: en el procesamiento, un id repetido sería un duplicado idempotente
// y no una venta nueva. La variante es una de las que load/fixtures.rb vinculó a
// un producto de carga, para que el evento también se pueda procesar.
function shopifyOrder(id, n, variantId) {
  return {
    id,
    name: `#LOAD${id}`,
    email: 'comprador@example.com',
    financial_status: 'paid',
    created_at: new Date().toISOString(),
    total_price: '100.00',
    currency: 'ARS',
    shipping_address: {
      name: `Carga ${id}`, address1: 'Calle 7 1234', city: 'La Plata',
      province: 'Buenos Aires', zip: '1900', phone: '+5492210000000',
    },
    line_items: [{ id: n + 1, variant_id: Number(variantId), quantity: 1, price: '100.00' }],
  };
}

export default function () {
  const n = exec.scenario.iterationInTest;
  const id = Date.now() * 1000 + (n % 1000);
  const variants = FIXTURES.webhook_variant_ids;
  const body = JSON.stringify(shopifyOrder(id, n, variants[n % variants.length]));
  const signature = crypto.hmac('sha256', FIXTURES.webhook_secret, body, 'base64');

  const res = http.post(
    `${BASE_URL}/api/webhooks/integrations/${FIXTURES.webhook_integration_id}`,
    body,
    {
      headers: {
        'Content-Type': 'application/json',
        [FIXTURES.webhook_signature_header]: signature,
        'X-Shopify-Topic': 'orders/create',
      },
      tags: { name: NAME },
    },
  );
  check(res, { 'webhook 202': (r) => r.status === 202 });
}

export const handleSummary = summaryFor('webhooks');
