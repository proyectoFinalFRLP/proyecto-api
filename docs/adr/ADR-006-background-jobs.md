# ADR-006: Background Jobs con Solid Queue

**Fecha:** 2026-04-03  
**Estado:** Aceptado

---

## Contexto

El OMS requiere procesamiento asíncrono en varios flujos críticos: sincronización de stock hacia plataformas externas, procesamiento de webhooks entrantes, reintentos automáticos de eventos fallidos, y consultas periódicas de estado logístico (cronjobs). Se necesita una infraestructura de colas robusta y compatible con el entorno de despliegue.

## Decisión

Se adopta **Solid Queue 1.4** como backend de Active Job.

Solid Queue usa la base de datos PostgreSQL como broker de mensajes, eliminando la necesidad de Redis u otras dependencias externas. Se configura como adaptador por defecto de Active Job en Rails 8.

Patrón estándar para jobs:

```ruby
# app/jobs/catalog/sync_stock_job.rb
module Catalog
  class SyncStockJob < ApplicationJob
    queue_as :default

    def perform(product_id, company_id)
      Current.company_id = company_id  # Inicializar tenant manualmente
      product = Product.find(product_id)
      # lógica de sincronización
    end
  end
end

# Encolar desde un PORO o controller:
Catalog::SyncStockJob.perform_later(product.id, Current.company_id)
```

**Cronjobs** se configuran en `config/solid_queue.yml` usando la funcionalidad de recurring tasks de Solid Queue.

## Alternativas consideradas

### Sidekiq

- ✅ El estándar de facto para background jobs en Rails — comunidad enorme
- ✅ Dashboard web (Sidekiq Web UI)
- ✅ Alto throughput con workers concurrentes (threads)
- ❌ **Requiere Redis** — dependencia adicional en desarrollo y producción
- ❌ Complejidad de operaciones adicional (Redis replication, persistence)
- ❌ En Rails 8 con Solid Queue, Redis no es necesario

### Delayed::Job

- ✅ También usa la base de datos, sin dependencias externas
- ❌ Más lento que Solid Queue para volúmenes altos
- ❌ Menos activo en desarrollo que Solid Queue

### GoodJob

- ✅ También DB-backed, buena integración con Rails
- ❌ Solid Queue es la solución oficial de Rails 8 — mejor soporte a largo plazo

## Consecuencias

- ✅ Sin dependencias adicionales: PostgreSQL ya es parte del stack
- ✅ Las jobs son transaccionales con el mismo commit que las dispara (Solid Queue soporta esto)
- ✅ Cronjobs declarativos en configuración YAML sin herramientas externas (cron del SO)
- ✅ Fácil de operar: la cola y los jobs son visibles en la misma DB que los datos
- ⚠️ Para volúmenes muy altos (> miles de jobs/seg), Redis-backed Sidekiq sería más performante
- ⚠️ Los jobs deben setear `Current.company_id` manualmente — el contexto HTTP no está disponible en background
