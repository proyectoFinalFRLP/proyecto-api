# ADR-007: Autorización con Pundit

**Fecha:** 2026-04-03  
**Estado:** Aceptado

---

## Contexto

La API necesita un sistema de autorización que controle qué acciones puede realizar cada usuario sobre cada recurso. El sistema es multi-tenant, por lo que la regla más fundamental es que un usuario solo puede operar sobre recursos de su propia empresa. Se requiere una solución que sea explícita, testeable y fácil de auditar.

## Decisión

Se adopta **Pundit 2.5** para la autorización.

Pundit define una **Policy** por recurso. Cada policy es una clase Ruby plain con métodos que responden `true`/`false` para cada acción.

Patrón estándar:

```ruby
# app/policies/order_policy.rb
class OrderPolicy < ApplicationPolicy
  def index?   = user.present?
  def show?    = record.company_id == user.company_id
  def create?  = user.present?
  def update?  = record.company_id == user.company_id
  def destroy? = false  # Las órdenes no se eliminan, se cancelan
end
```

El `ApplicationController` incluye `include Pundit::Authorization` y define `pundit_user` retornando el `current_user`.

Uso en controllers:

```ruby
def show
  @order = Order.find(params[:id])
  authorize @order            # Llama a OrderPolicy#show?
  render json: OrderSerializer.render(@order)
end

def index
  @orders = policy_scope(Order)  # Aplica OrderPolicy::Scope
  render json: OrderSerializer.render(@orders)
end
```

## Alternativas consideradas

### CanCanCan

- ✅ Ampliamente usado, define todos los permisos en un solo `Ability` class
- ❌ El `Ability` class crece indefinidamente con el sistema
- ❌ Más difícil de testear cada permiso en aislamiento
- ❌ Modelo mental menos explícito que Pundit

### Autorización manual (sin gema)

- ✅ Sin dependencias, control total
- ❌ Fácil olvidar verificaciones de autorización en endpoints nuevos
- ❌ Pundit ya provee `verify_authorized` y `verify_policy_scoped` para prevenir esto

### Action Policy

- ✅ Similar a Pundit pero con caching de políticas y mejor performance
- ❌ Menor adopción y comunidad
- ❌ Para el alcance del proyecto, la diferencia de performance es irrelevante

## Consecuencias

- ✅ Cada policy es una clase Ruby plain, 100% testeable sin fixtures ni base de datos
- ✅ Las policies son explícitas: saber qué puede hacer un usuario = leer su policy
- ✅ Pundit falla ruidosamente si se olvida llamar a `authorize` — reduce errores de seguridad
- ✅ `policy_scope` en `index` aplica el scope correcto automáticamente
- ⚠️ Requiere llamar `authorize` explícitamente en cada acción del controller — es verboso pero intencional
- ⚠️ Para RBAC (roles granulares), Pundit requiere lógica adicional en las policies — fuera del scope MVP
