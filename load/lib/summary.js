// Resumen de fin de corrida: el texto de siempre por consola y, además, el JSON
// completo en load/results/<escenario>.json para pasar números al informe.

import { textSummary } from 'https://jslib.k6.io/k6-summary/0.1.0/index.js';

export const TREND_STATS = ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max', 'count'];

export function summaryFor(name) {
  return (data) => ({
    stdout: textSummary(data, { indent: ' ', enableColors: false }),
    [`${__ENV.RESULTS_DIR || 'results'}/${name}.json`]: JSON.stringify(data, null, 2),
  });
}
