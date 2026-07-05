# ADR-003: Estrategia de Multi-tenancy (Row-Level)

**Fecha:** 2026-04-03  
**Estado:** Aceptado

---

## Contexto

El OMS debe servir a múltiples empresas (tenants) con aislamiento total de datos: una empresa no puede ver ni acceder a los datos de otra. Se necesita elegir una estrategia de multi-tenancy que sea simple de implementar, segura y que no requiera infraestructura adicional.

## Decisión

Se implementa **row-level multi-tenancy**: todas las empresas comparten la misma base de datos y los mismos esquemas de tablas. El aislamiento se garantiza mediante:

1. **`company_id NOT NULL`** en todas las tablas de dominio, con FK a la tabla `companies`.
2. **`ActiveSupport::CurrentAttributes`**: la clase `Current` expone `Current.company_id`, que se setea al inicio de cada request desde el payload del JWT.
3. **Global Default Scope en `ApplicationRecord`**: todas las queries de dominio incluyen automáticamente `WHERE company_id = Current.company_id`.

```ruby
# app/models/application_record.rb
class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class
  default_scope { where(company_id: Current.company_id) if Current.company_id }
end
```

```ruby
# app/models/current.rb
class Current < ActiveSupport::CurrentAttributes
  attribute :company_id
  attribute :user
end
```

## Alternativas consideradas

### Schema-per-tenant (PostgreSQL schemas)

- ✅ Aislamiento a nivel de esquema: imposible acceder a datos de otro tenant con queries accidentales
- ✅ Backup/restore selectivo por empresa es simple
- ❌ Overhead de gestión: N schemas para N tenants (migraciones complejas)
- ❌ Requiere herramientas adicionales (Apartment gem o similar)
- ❌ Pool de conexiones crece linealmente con tenants

### Database-per-tenant

- ✅ Máximo aislamiento y posibilidad de sharding geográfico
- ❌ Infraestructura costosa: una base de datos por cliente
- ❌ Gestión de credenciales por tenant
- ❌ Completamente excesivo para el alcance del proyecto

## Consecuencias

- ✅ Una sola migración se aplica a todos los tenants simultáneamente
- ✅ El scope automático elimina la necesidad de filtros manuales en cada query
- ✅ No se requiere infraestructura adicional (sin Redis, sin schemas separados)
- ⚠️ Un bug en el Global Default Scope podría exponer datos cross-tenant — debe testearse exhaustivamente
- ⚠️ Los workers de background deben setear `Current.company_id` manualmente antes de operar
- ⚠️ Las queries administrativas (monitoring, seeds) deben usar `unscoped` explícitamente
- ⚠️ "Noisy neighbor": un tenant con alto volumen puede impactar el rendimiento de otros en la misma DB
