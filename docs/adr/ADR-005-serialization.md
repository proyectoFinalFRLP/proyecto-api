# ADR-005: Serialización JSON con Blueprinter

**Fecha:** 2026-04-03  
**Estado:** Aceptado

---

## Contexto

La API devuelve JSON en todos sus endpoints. Se necesita una forma de definir el formato de respuesta de cada recurso que sea declarativa, reutilizable y que permita controlar qué campos se exponen (evitando exponer campos internos como `encrypted_password`, `company_id` en ciertos contextos, etc.).

## Decisión

Se adopta **Blueprinter 1.2** para la serialización JSON.

Cada recurso tiene su propio serializer en `app/serializers/`, heredando de `ApplicationSerializer < Blueprinter::Base`.

Patrón estándar:

```ruby
class OrderSerializer < ApplicationSerializer
  identifier :id
  fields :status, :source, :total_amount, :created_at

  association :order_items, blueprint: OrderItemSerializer
  association :company,     blueprint: CompanySerializer
end

# Uso en controller:
render json: OrderSerializer.render(@order)
render json: OrderSerializer.render(@orders)  # También funciona con colecciones
```

## Alternativas consideradas

### Active Model Serializers (AMS)

- ✅ Integración nativa con Rails, ampliamente usado
- ❌ Desarrollo estancado, inconsistencias en el comportamiento de asociaciones
- ❌ API confusa con múltiples adaptadores (JSON, JSON:API)

### Jbuilder

- ✅ Incluido en Rails, sintaxis de template familiar
- ❌ Lógica de serialización mezclada con templates (`.json.jbuilder`)
- ❌ No aplica en modo API-only con la misma comodidad
- ❌ Más difícil de reutilizar y testear

### fast_jsonapi (jsonapi-serializer)

- ✅ Muy performante para colecciones grandes, sigue JSON:API spec
- ❌ El formato JSON:API es más verboso de lo necesario para este proyecto
- ❌ El frontend consume una API propia — no hay beneficio de seguir la spec JSON:API

### Representable / Roar

- ✅ Muy flexible para HATEOAS
- ❌ Complejidad excesiva para el alcance del proyecto

## Consecuencias

- ✅ Los serializers son declarativos y fáciles de leer
- ✅ Blueprinter soporta vistas (`:extended`, `:compact`) para exponer distintos campos según el contexto
- ✅ El mismo serializer funciona para objetos individuales y colecciones
- ✅ Separación clara entre la lógica del modelo y el formato de respuesta
- ⚠️ Las asociaciones se renderizan siempre a menos que se use una vista más liviana — tener cuidado con N+1 queries
