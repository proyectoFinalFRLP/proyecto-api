# Pruebas de carga: endpoints críticos (TESIS-96)

Informe de la corrida de referencia de las pruebas de carga sobre los endpoints de mayor uso. Los
scripts, cómo se preparan los datos y cómo se corren (local o contra un entorno desplegado) están
en [`load/README.md`](../../load/README.md).

**Fecha:** 2026-10-21 · **Herramienta:** k6 v1.3.0 · **Umbral de la card:** p95 < 500 ms

---

## 1. Resumen

| Escenario (card) | Carga | ¿Cumple p95 < 500 ms? |
| --- | --- | --- |
| Alta de órdenes, 50 req/s | `POST /orders`, 60 s | **Al límite.** 3 de 6 corridas cumplen (p95 47–413 ms); las otras 3 se saturan (p95 de 0,5 s a 15 s) |
| Ingesta de webhooks, 100 req/s | `POST /webhooks/integrations/:id` firmado, 60 s | **Sí.** p95 67 ms, 0 errores |
| Stock con locks, 20 workers sobre un SKU | `POST /orders` del mismo producto, 30 s | **Sí.** p95 236 ms, stock consistente, 0 respuestas inesperadas |
| Listado de órdenes paginado | `GET /orders` a 30 req/s (+ catálogo y envíos), 60 s | **Sí.** p95 59 ms; con búsqueda, 119 ms |
| Login (complementario) | `POST /auth/login`, 5 y 15 req/s, 30 s | **Sí.** p95 188 ms (es bcrypt) |

La conclusión corta: **en esta máquina y con la configuración del despliegue —un proceso de Puma
con 3 hilos— la API atiende ~50–60 altas de orden por segundo y no más**, y a 50 req/s está justo
en el codo de la curva: la misma prueba pasa con p95 de 47 ms o se satura según lo que pase
alrededor. El resto de los escenarios de la card tiene margen de sobra; la salvedad es que los
webhooks se aceptan a 100/s pero se procesan a ~40–60/s, así que una ráfaga deja cola. El cuello
de botella es CPU de Ruby en un solo proceso, no la base ni los locks (§5).

---

## 2. Entorno

| | |
| --- | --- |
| Máquina | AMD Ryzen 5 8400F (6 núcleos / 12 hilos, 4,2 GHz), 15,6 GB de RAM |
| Sistema | Windows 11 Pro |
| Ruby / Rails | 4.0.2 **sin YJIT** (el build de Windows no lo trae) / 8.1.4 |
| PostgreSQL | 18, en la misma máquina |
| Servidor | Puma 8 con `config/puma.rb` del repo: **1 proceso, 3 hilos** (`RAILS_MAX_THREADS` default), `-b tcp://127.0.0.1:3100` |
| Modo | `RAILS_ENV=production` (eager load, sin recarga, logs en `warn`, caché en Solid Cache) |
| Bases | Cuatro propias de la prueba (`proyecto_api_loadtest{,_cache,_queue,_cable}`), borradas al terminar |
| Generador | k6 en la misma máquina |

**Datos:** los seeds más `load/fixtures.rb`: 200 productos con 1 000 000 de unidades cada uno, un
producto caliente para la contención, la integración de Shopify con secreto conocido y una
variante vinculada por producto, y 20 000 órdenes históricas. Con lo que fueron creando las
propias corridas, el listado de órdenes se midió sobre ~39 000 órdenes de la empresa.

**Cómo se parece al despliegue.** El despliegue (`config/deploy.yml`) también corre un solo
proceso de Puma con 3 hilos y no fija `WEB_CONCURRENCY`, así que el techo de un proceso que se
mide acá es el mismo techo que tiene producción. Lo que cambia: allá Ruby corre con YJIT (Linux),
que suele bajar el costo de CPU por request; allá la API comparte la máquina con los workers
(`SOLID_QUEUE_IN_PUMA`), que acá no corrieron; y allá hay red y TLS (Thruster) entre el cliente y
Puma. Los números absolutos no se trasladan, la forma de la curva sí.

---

## 3. Resultados

Latencias en milisegundos, medidas por k6 (tiempo total del request, del lado del cliente).
Throughput = requests completados por segundo. Error = respuestas fuera de lo esperado.

### 3.1 Alta de órdenes — `POST /api/v1/orders`

Una línea de 1 unidad, productos en ronda sobre 200 (para que el lock `wait: false` no choque
entre órdenes simultáneas; la contención se mide aparte en §3.3).

| Corrida | Tasa pedida | Throughput | p50 | p95 | p99 | Máx | Error | Descartadas | Resultado |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 40 req/s | 40 | 39,9 | 25 | 42 | 92 | 146 | 0 % | 0 | ✅ |
| 50 req/s (1) | 50 | 44,6 | 63 | 7 771 | 8 606 | 8 720 | 0 % | 232 | ❌ saturada |
| 50 req/s (2) | 50 | 49,9 | 30 | 104 | 243 | 282 | 0 % | 0 | ✅ |
| 50 req/s (3) | 50 | 49,9 | 27 | 413 | 893 | 999 | 0 % | 0 | ✅ |
| 50 req/s (4, en frío) | 50 | 49,5 | 233 | 539 | 616 | 707 | 0 % | 0 | ❌ por 39 ms |
| 50 req/s (5) | 50 | 31,8 | 115 | 14 940 | 15 130 | 15 210 | 0 % | 790 | ❌ saturada |
| 50 req/s (6, 45 s) | 50 | 49,8 | 22 | 47 | 84 | 191 | 0 % | 0 | ✅ |
| 60 req/s | 60 | 59,8 | 59 | 204 | 248 | 311 | 0 % | 0 | ✅ |
| 80 req/s | 80 | 35,4 | 7 739 | 23 302 | 24 059 | 24 334 | 0 % | 2 418 | ❌ saturada |
| 80 req/s, **6 hilos** | 80 | 63,2 | 3 874 | 8 340 | 9 165 | 9 235 | 0 % | 397 | ❌ saturada |

"Descartadas" son iteraciones que k6 no llegó a lanzar porque todos sus VUs estaban esperando
respuesta: la señal de que el servidor dejó de seguir el ritmo pedido.

### 3.2 Ingesta de webhooks — `POST /api/webhooks/integrations/:id`

Venta de Shopify (`orders/create`) con firma HMAC-SHA256 válida. Mide la **aceptación**: verificar
la firma, guardar el `WebhookLog`, encolar el job y responder 202.

| Tasa pedida | Throughput | p50 | p95 | p99 | Máx | Error |
| --- | --- | --- | --- | --- | --- | --- |
| 100 req/s | 100,0 | 8,5 | 67 | 136 | 199 | 0 % (6 001 × 202) |

**Procesamiento.** Los workers de Solid Queue no corren con Puma en Windows (ver
`architecture.md` §8.3), así que durante la corrida los eventos sólo se acumularon en la cola. El
costo de procesarlos se midió aparte: ejecutando `Orders::ProcessWebhookEventJob` en línea, un hilo,
sobre 1 000 de esos eventos, todos terminaron `processed` (orden creada, stock descontado) a
**62 eventos/s (~16 ms cada uno)**.Después se drenaron los otros 5 001 con un
worker real (`bin/worker_windows.rb`, 3 hilos, sólo la cola `realtime`): **~115 s, ~43 eventos/s
de promedio**, con tramos de ~65/s y un tramo de ~20/s, todos `processed` y ninguno `failed`. Los
3 hilos del worker no rinden más que uno en línea: el procesamiento también es CPU de Ruby bajo el
GVL. Una ráfaga de 60 s a 100 eventos/s deja, entonces, unos 2 minutos de cola.

### 3.3 Concurrencia de stock — 20 workers sobre el mismo SKU

20 VUs sin pausa dando de alta órdenes de 1 unidad del mismo producto durante 30 s.

| Métrica | Valor |
| --- | --- |
| Requests | 3 218 (105,7/s) |
| Órdenes creadas (201) | 1 492 (48,9/s) |
| Rechazadas por lock ocupado (409) | 1 726 (53,6 %) |
| Otras respuestas (5xx, 422…) | 0 |
| Latencia p50 / p95 / p99 / máx | 189 / 236 / 256 / 326 ms |
| Stock inicial → final | 999 745 → 998 253 (−1 492) |
| **Consistencia** (descontado = órdenes creadas) | ✅ 1 492 = 1 492 |

### 3.4 Listados (pantallas principales)

Los tres en paralelo, a tasa constante cada uno. El de órdenes reparte un tercio de páginas al
azar entre las primeras 50, un tercio con filtro de estado y un tercio con búsqueda.

| Endpoint | Tasa | p50 | p95 | p99 | Máx | Error |
| --- | --- | --- | --- | --- | --- | --- |
| `GET /orders` (página / estado) | 20 req/s | 31 | 59 | 81 | 111 | 0 % |
| `GET /orders?search=` | 10 req/s | 76 | 119 | 140 | 160 | 0 % |
| `GET /products` (con y sin búsqueda) | 10 req/s | 25 | 38 | 50 | 67 | 0 % |
| `GET /shipments` | 10 req/s | 28 | 48 | 66 | 98 | 0 % |
| **Total** | 49,9 req/s | | | | | 0 % (3 004 requests) |

### 3.5 Login — `POST /api/v1/auth/login`

| Tasa | p50 | p95 | p99 | Máx | Error |
| --- | --- | --- | --- | --- | --- |
| 5 req/s | 175 | 188 | 194 | 200 | 0 % |
| 15 req/s | 175 | 183 | 185 | 188 | 0 % |

---

## 4. Consultas por request

Contadas en proceso (sin HTTP) con `ActiveSupport::Notifications`, sin contar `BEGIN`/`COMMIT`:

| Endpoint | Consultas | Tiempo en proceso |
| --- | --- | --- |
| `POST /orders` (1 línea) | 21 | ~12 ms |
| `GET /orders` | 7 | ~15 ms |
| `GET /orders?search=` | 7 | ~34 ms |
| `GET /products` | 7 | ~13 ms |
| `GET /shipments` | 9 | ~50 ms (primera llamada) |
| `POST /webhooks/...` | 7 | ~26 ms (primera llamada) |

Los listados no tienen N+1: la cantidad de consultas no depende del tamaño de la página (las
precargas de `OrdersController#index`, `ProductsController#index` y `ShipmentsController#index`
hacen su trabajo). El alta de una orden de una línea hace 21 consultas; de ellas, 4 se repiten por
línea (el `Warehouse.exists?` de `CreateOrder` y las relecturas de producto y depósito que hacen
las validaciones `belongs_to` de `OrderItem` y `Stock`). Con el tope de 100 líneas son ~400
consultas: caro, pero acotado y lejos del caso común. No se tocó.

---

## 5. Conclusiones y cuellos de botella

**1. El techo es un proceso de Ruby, no la base.** Una orden cuesta ~12 ms de CPU de Ruby en
proceso y ~20 ms por HTTP sin carga. Con el GVL, los 3 hilos de Puma sólo se reparten la espera de
la base: el proceso usa a lo sumo un núcleo, y eso pone el techo del alta en ~60 req/s en esta
máquina. Subir a 6 hilos no lo movió (63 req/s a 80 pedidos, saturado igual), y una muestra de
`pg_stat_activity` tomada durante una corrida a 50 req/s no mostró esperas en la base (conexiones
`idle` o activas sin `wait_event`). Por eso a 50 req/s la prueba queda en el codo: a ~80 % de utilización cualquier
interferencia —el arranque en frío, otro proceso de la máquina (durante las corridas había otra
API de desarrollo levantada en el puerto 3000), una pausa de GC— forma una cola, k6 suma VUs para
sostener la tasa, y con cientos de conexiones abiertas el proceso rinde todavía menos (35 req/s a
80 pedidos con 3 hilos, contra 60 sin saturar). No se recupera dentro de la ventana de 60 s.

**Recomendación** (no se aplica en este PR, es configuración del despliegue): en Linux, Puma
corre en modo cluster con `WEB_CONCURRENCY` (Puma lo lee solo, sin tocar `config/puma.rb`). Con
`WEB_CONCURRENCY=2` el techo de altas debería acercarse al doble si el servidor tiene dos núcleos
libres (no se pudo medir: Windows no tiene modo cluster), a cambio de memoria (un proceso más de
~200 MB) y del doble de conexiones a la base (2 × 3 hilos más los workers de Solid Queue, lejos
del `max_connections` default de PostgreSQL, 100). YJIT suma margen: Rails lo activa solo cuando
el Ruby de la imagen está compilado con él. Conviene repetir esta prueba sobre la imagen Docker
antes de decidir.

**2. La ingesta de webhooks aguanta 100 req/s con margen; el procesamiento, no.** Aceptar un
evento cuesta ~9 ms (p50), pero procesarlo cuesta ~16 ms de CPU, y un proceso de worker drena
~43–62 eventos/s (§3.2). Una ráfaga sostenida
de 100 eventos/s se acepta toda y deja cola: es justamente lo que el diseño de ADR-010 busca (el
proveedor recibe su 202 enseguida y nada se pierde), pero la cola tarda en drenar más que la
ráfaga en llegar. En el despliegue los workers comparten CPU con la API, así que una ráfaga de
webhooks también le resta capacidad al alta manual mientras se drena.

**3. Los locks de stock hacen lo que dicen.** Con 20 workers sobre el mismo SKU no se perdió ni se
duplicó una unidad (1 492 órdenes, 1 492 unidades), no hubo un solo 5xx, y el 409 apareció en más
de la mitad de los intentos: es el contrato de `wait: false` (ADR-009), que prefiere rechazar al
instante a colgar un hilo de Puma. Dos lecturas para el equipo:

- **Throughput del SKU caliente:** ~49 órdenes/s efectivas, el mismo techo del proceso. El lock
  no agrega un cuello propio: con 3 hilos, rara vez hay más de una orden del mismo producto en
  vuelo cuando la otra pide el lock.
- **El 409 lo tiene que reintentar el cliente.** Para el alta manual (una persona) es raro y
  razonable. Si algún día entran ventas de un mismo producto por la API en ráfaga, conviene que el
  cliente reintente con backoff; los webhooks no tienen el problema porque el worker espera el
  lock (`wait: true`).
- La latencia de 189 ms (p50) de este escenario es cola, no lock: 20 clientes sin pausa contra
  3 hilos.

**4. Los listados están lejos del umbral.** El listado de órdenes paginado responde en 59 ms (p95)
sobre ~39 000 órdenes. Dos costos que crecen con el volumen, medidos con `EXPLAIN ANALYZE`:

- La página por default (`ORDER BY created_at DESC, id DESC`) hoy es un seq scan con *top-N
  heapsort* (4,6 ms a 39 000 filas), porque `orders` sólo tiene índice en `company_id`. Un índice
  `(company_id, created_at DESC, id DESC)` la baja a 0,1 ms (probado en la base de la prueba y
  descartado). No se agregó: a este volumen son 4 ms de 59, y crecen lineal (~45 ms a 400 000
  órdenes por empresa). Queda como recomendación para cuando una empresa pase las ~100 000.
- El `meta.total` cuenta con otro seq scan (3,4 ms) que ese índice no evita: paginar con total
  exige contar.
- La búsqueda (`ILIKE '%término%'` sobre cinco columnas) es el camino más caro, 119 ms p95, y
  tampoco puede usar un B-tree. Ya está documentado en el controller como card aparte (`pg_trgm`).

**5. El login es bcrypt.** 175 ms por login, plano entre 5 y 15 req/s: es el costo de 12 rondas de
bcrypt, que es deliberado. El techo teórico con 3 hilos es ~17 logins/s; es una tasa muy por
encima de la de operadores abriendo sesión. Los scripts autentican una sola vez y reutilizan el
token, para no medir bcrypt en cada escenario.

---

## 6. Salvedades

- **Una sola máquina para todo.** k6, Puma y PostgreSQL compartieron la CPU, y la máquina no
  estaba aislada (había otra API de desarrollo levantada y otras tareas corriendo). Explica parte
  de la varianza a 50 req/s; también hace que los números sean conservadores frente a un
  servidor dedicado.
- **Windows y sin YJIT.** Ruby en Windows y sin JIT es, en general, más lento que en una imagen
  Linux con YJIT. Tampoco hay modo cluster de Puma en Windows, así que la recomendación de
  `WEB_CONCURRENCY` no se pudo medir acá.
- **Sin workers durante las corridas.** Cada alta de orden encola un `SyncStockToChannelsJob` y
  cada webhook un `ProcessWebhookEventJob`; en el despliegue esos jobs corren en el mismo proceso
  que la API y le restan CPU. Acá se midió la API sola, y el procesamiento aparte (§3.2).
- **Sin red ni TLS.** El cliente le pega a Puma por loopback; no está Thruster adelante.
- **Volumen de datos.** ~39 000 órdenes y ~210 productos en una empresa: representativo de una
  empresa mediana, no de una grande.
- **Tasas constantes.** Las pruebas sostienen una tasa fija; no modelan picos ni el patrón real
  de uso de la pantalla.

---

## 7. Cómo repetirlo

Ver [`load/README.md`](../../load/README.md). Resumen: base propia con `DATABASE_URL` y sus
hermanas, `bin/rails db:prepare db:seed`, `bin/rails runner load/fixtures.rb`, Puma en un puerto
libre, y `k6 run` de cada script desde `load/`. Los JSON completos de cada corrida quedan en
`load/results/` (fuera de git).
