# ADR-008: Motor de reintentos con Dead Letter Queue

**Fecha:** 2026-07-30  
**Estado:** Aceptado

---

## Contexto

El OMS depende de APIs de terceros (Mercado Libre, Tiendanube, couriers) que fallan de forma transitoria: timeouts, 5xx, cortes de red. Hoy `Integrations::HttpAdapter` levanta `AdapterExecutionError` y el evento se pierde: si la sincronización de stock hacia un canal falla, el canal queda desactualizado sin registro alguno.

Se necesita que ningún evento de integración se pierda, que los fallos transitorios se recuperen solos, y que los definitivos queden visibles y reprocesables sin tocar la base de datos a mano.

## Decisión

Se implementa una **Dead Letter Queue persistida en PostgreSQL** (tabla `failed_events`) con un motor de reintentos basado en el cronjob de Solid Queue.

**Por qué en tabla propia y no con el `retry_on` de Active Job:** los reintentos de Active Job viven en el proceso del worker y con backoffs largos ocupan la cola; además, un evento que agota sus reintentos desaparece en el log. Una tabla propia hace el estado consultable por API, sobrevive a reinicios y permite reintento manual.

**Relación con el `retry_on` de `ApplicationJob`** (definido en TESIS-37 para `Integrations::AdapterExecutionError`): los dos mecanismos no se pisan porque la DLQ **rescata antes**. `ExecuteIntegrationRequest` captura el `AdapterExecutionError` y lo persiste, y `RetryFailedEvent` nunca propaga la excepción de un reintento. Un fallo que pasa por la DLQ no vuelve a contar como fallo del job. El `retry_on` sigue cubriendo las llamadas salientes que todavía no pasan por acá.

### Ciclo de vida

```
pending ──(cron encola)──> processing ──(éxito)────> succeeded
   ^                            │
   └───(fallo, quedan intentos)─┤
                                └───(sin intentos)──> dead ──(retry manual)──> pending
```

`discarded` es la salida manual: el operador decide que el evento ya no debe reintentarse.

### Componentes

| Pieza                                   | Rol                                                        |
| --------------------------------------- | ---------------------------------------------------------- |
| `FailedEvent`                           | Estado del evento + backoff (`CompanyScoped`)              |
| `Webhooks::RegisterFailedEvent`         | Punto de entrada: persiste el fallo y agenda el 1er intento |
| `Webhooks::ExecuteIntegrationRequest`   | Envuelve al `HttpAdapter`: deriva el fallo a la DLQ         |
| `Webhooks::ScanDueFailedEventsJob`      | Cronjob (cada minuto): barre eventos vencidos de todos los tenants |
| `Webhooks::RetryFailedEventJob`         | Reclama el evento (claim atómico) y ejecuta un intento     |
| `Webhooks::RetryFailedEvent`            | Ejecuta el replay y persiste el resultado                  |
| `Webhooks::ReplayRegistry`              | Mapea `event_type` → PORO que sabe reprocesar              |
| `Api::V1::FailedEventsController`       | Inspección, reintento manual y descarte                    |

Ambos jobs corren en la cola `low` ([ADR-006](ADR-006-background-jobs.md)): reintentos y tareas programadas no compiten con los eventos entrantes de `realtime`.

### Backoff

Exponencial con jitter: `1m, 2m, 4m, 8m, 16m` (+ hasta 30s de dispersión), 5 intentos por defecto (`FailedEvent::DEFAULT_MAX_ATTEMPTS`). El jitter evita que un lote de eventos que falló junto —típico de una caída de proveedor— reintente todo en el mismo tick.

### Concurrencia

El cron encola y el worker reclama: `UPDATE ... WHERE id = ? AND status = 'pending'`. Si el update afecta 0 filas, otro worker ya tomó el evento y el job termina sin hacer nada. No hace falta un lock distribuido.

### Multi-tenancy

`failed_events` tiene `company_id NOT NULL` e incluye `CompanyScoped`. El cronjob es el único job que corre **sin** contexto de tenant: usa `unscoped` para barrer todas las empresas y le pasa el `company_id` a cada job, que lo activa con el helper `with_tenant` de `ApplicationJob` antes de tocar la base.

### Extensibilidad

El motor no conoce ningún dominio: busca en `ReplayRegistry` el PORO correspondiente al `event_type` y lo ejecuta. Sumar los webhooks entrantes (TESIS-36) o el sync de stock (TESIS-21) es registrar un replayer nuevo, sin tocar el motor.

## Alternativas consideradas

### `retry_on` de Active Job

- ✅ Cero código: una línea en el job
- ❌ El evento vive solo en la cola; no es consultable ni reprocesable desde la API
- ❌ Un evento que agota reintentos se pierde en el log
- ❌ Backoffs largos mantienen jobs ocupando la cola

### Redis + Sidekiq con dead set

- ✅ Dashboard listo, dead set nativo
- ❌ Requiere Redis, ya descartado en [ADR-006](ADR-006-background-jobs.md)

### Reintento sincrónico dentro del PORO

- ✅ Simple, sin infraestructura
- ❌ No sobrevive a un reinicio ni a una caída larga del proveedor
- ❌ Bloquea el request HTTP del usuario

## Consecuencias

- ✅ Ningún evento de integración se pierde: todo fallo queda persistido y auditable
- ✅ Los fallos transitorios se recuperan sin intervención humana
- ✅ La DLQ es consultable y reprocesable desde `/api/v1/failed-events`
- ✅ Agregar tipos de evento nuevos no toca el motor
- ⚠️ El barrido corre cada minuto: la latencia mínima de un reintento es de ~1 minuto
- ⚠️ La tabla crece con cada fallo; los eventos `succeeded`/`discarded` necesitarán una política de limpieza (fuera del alcance de TESIS-39)
- ⚠️ El `payload` se guarda en claro en la tabla: no se expone por API, pero conviene revisarlo si en el futuro incluye datos sensibles del cliente
