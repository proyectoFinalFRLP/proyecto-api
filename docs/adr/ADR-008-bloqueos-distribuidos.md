# ADR-008: Bloqueos distribuidos para el control de concurrencia de stock

**Fecha:** 2026-08-10  
**Estado:** Aceptado

---

## Contexto

Toda mutación de stock tiene que quedar serializada por producto a través de todos los procesos concurrentes que pueden tocarla: varios workers de Puma atendiendo requests HTTP, varios workers de Solid Queue procesando jobs y, eventualmente, varias instancias desplegadas del mismo proceso. Hoy `Products::UpdateProduct` hace un `find_or_initialize_by` + `save!` dentro de una transacción de ActiveRecord: dos requests simultáneos sobre el mismo producto pueden leer el mismo valor de stock y pisarse la escritura (lost update), o intentar crear la misma fila de `stocks` al mismo tiempo. Un `Mutex` de Ruby no resuelve nada acá: es un lock por proceso, y el problema es entre procesos — y eventualmente entre instancias desplegadas.

## Decisión

Se adoptan **advisory locks de PostgreSQL a nivel de transacción**, encapsulados en un PORO reutilizable: `Shared::WithAdvisoryLock` (`app/poros/shared/with_advisory_lock.rb`). Vive en `poros/shared/` porque, por la "Regla de Dos" de [`feature-structure.md`](../guidelines/feature-structure.md), lo van a usar al menos dos dominios: `catalog` (ABM de productos y stock) y `orders` (descuento de stock al confirmar una orden).

Interfaz:

```ruby
Shared::WithAdvisoryLock.new(product_id: product.id).call do
  # sección crítica: escrituras de stock
end

# En requests HTTP interactivos conviene fallar rápido en vez de colgar un thread de Puma:
Shared::WithAdvisoryLock.new(product_id: product.id, wait: false).call { ... }
```

**`pg_advisory_xact_lock` y no `pg_advisory_lock` (TESIS-38).** El lock se toma a nivel de transacción y el motor lo libera solo, en el `COMMIT` o el `ROLLBACK`. El lock a nivel de sesión (`pg_advisory_lock` / `pg_advisory_unlock`) exige que el propio código libere el lock explícitamente: un proceso que muere entre el `lock` y el `unlock` lo deja tomado hasta que se cierre la conexión, y con un pool de conexiones esa conexión puede seguir viva horas. Con el lock transaccional no hay locks huérfanos que barrer.

**Clave del lock (TESIS-38).** Es un entero de 64 bits derivado por SHA-256 de `"#{namespace}:#{company_id}:#{product_id}"`, con `namespace = 'stock'`. El `company_id` entra en la clave para que dos empresas nunca compitan por el mismo lock, aunque tengan productos con el mismo `id` numérico. El namespace deja lugar para futuros recursos bloqueables (por ejemplo, un lock sobre la confirmación de una orden en `orders`) sin colisionar con las claves de stock.

**`Current.company_id` es obligatorio (TESIS-38).** La tabla `stocks` no tiene columna `company_id` propia — llega indirectamente por `product` — así que la clave del lock depende del tenant activo en `Current`. Si `Current.company_id` viniera en `nil`, la clave dejaría de aislar empresas y dos tenants distintos podrían terminar compitiendo por el mismo lock. El PORO levanta `ArgumentError` en ese caso en vez de continuar silenciosamente: es la misma clase de falla ruidosa que ya eligió `ApplicationJob#with_tenant` para el mismo problema (ver [ADR-003](ADR-003-multitenancy.md)).

**Granularidad por producto, no por producto + depósito (TESIS-38).** Un update del ABM de productos puede tocar varias filas de `stocks` del mismo producto en un solo request, y algunas de esas filas todavía pueden no existir. Bloquear por depósito hubiera exigido tomar N locks en un orden estable para evitar deadlocks entre transacciones que actualizan los mismos depósitos en orden distinto. Se asume el costo: si una empresa mueve stock del mismo producto en depósitos distintos al mismo tiempo, esas escrituras se serializan de más aunque no compitan por la misma fila.

**`lock_timeout` configurable (TESIS-38).** El PORO ejecuta `SET LOCAL lock_timeout` antes de tomar el lock (3000 ms por default): una espera no puede bloquear indefinidamente un worker de Puma o de Solid Queue. Vencido el timeout, se levanta `Shared::LockTimeoutError`, que `ApplicationController` mapea a **409 Conflict**.

**`wait: true` vs `wait: false` (TESIS-38).** El PORO expone las dos variantes que ofrece PostgreSQL: `pg_advisory_xact_lock` (espera hasta el `lock_timeout`, es el comportamiento con `wait: true`, el default) y `pg_try_advisory_xact_lock` (no espera, devuelve al instante si el lock está tomado, `wait: false`). Un job de background puede permitirse esperar y confiar en el reintento de Active Job si aun así falla; un request HTTP interactivo no debería dejar un thread de Puma colgado esperando un lock — conviene fallar rápido con 409 y que el cliente reintente.

**`SELECT ... FOR UPDATE` como complemento, no como reemplazo (TESIS-38).** `Stock#lock!` sirve para serializar una fila de `stocks` que ya existe, pero no protege el caso en que la fila todavía no existe: dos transacciones concurrentes no tienen nada que bloquear y ambas intentan el `INSERT`. Por eso el advisory lock cubre las operaciones que abarcan varias filas o que pueden crear la fila, y `lock!` se sigue usando *dentro* del advisory lock para releer, con el valor vigente en la base, la fila que el controller pudo haber precargado —y que puede estar desactualizada— a través de `product.stocks`.

**`CHECK (quantity >= 0)` sobre `stocks` (TESIS-38, migración `20260810120000`, restricción `stocks_quantity_non_negative`).** Es la última línea de defensa, independiente del código de aplicación: la validación de `Stock` no corre en escrituras batch (`update_all`, `upsert_all`) ni en SQL crudo, pero el `CHECK` de la base sí. `ApplicationController` lo mapea a 422.

**El control de concurrencia de Solid Queue es complementario, no sustituto (TESIS-38).** `limits_concurrency` y `concurrency_key` limitan cuántos jobs del mismo tipo corren a la vez, pero no saben nada de los requests HTTP que corren en paralelo en Puma. Un `limits_concurrency` por producto no impide que un ABM manual pise el stock que está escribiendo un job en simultáneo — el advisory lock es el único mecanismo que ve a los dos mundos a la vez.

## Alternativas consideradas

### Redis + Redlock

- ✅ Patrón conocido para locks distribuidos
- ❌ Mete Redis al stack, exactamente lo que [ADR-006](ADR-006-background-jobs.md) evitó al elegir Solid Queue sobre PostgreSQL
- ❌ Redlock es un algoritmo discutido: sin fencing tokens no garantiza exclusión mutua ante pausas largas de GC o relojes desincronizados entre nodos
- ❌ Agrega un punto de falla nuevo; PostgreSQL ya está en el stack y ya es la fuente de verdad del stock — el lock vive donde viven los datos

### Optimistic locking de ActiveRecord (`lock_version`)

- ✅ Sin infraestructura adicional, soportado nativamente por ActiveRecord
- ❌ No protege la creación de la fila: dos `INSERT` concurrentes chocan contra el índice único, no contra `lock_version`
- ❌ Convierte toda contención en un `StaleObjectError` que el usuario tiene que reintentar manualmente
- ❌ Obliga a agregar la columna `lock_version` y una capa de reintentos en cada punto de escritura
- Sirve para conflictos raros de edición humana, no para un recurso con escrituras concurrentes esperables desde varios canales (ABM, jobs de sync, webhooks)

### Sólo `SELECT ... FOR UPDATE`

- ✅ Sin infraestructura adicional, sintaxis estándar de ActiveRecord (`lock!`)
- ❌ No cubre la fila inexistente: dos transacciones concurrentes que quieren crear la misma fila no tienen nada que bloquear entre sí
- Se adopta como complemento del advisory lock, no como alternativa

### Nivel de aislamiento `SERIALIZABLE`

- ✅ Correcto: PostgreSQL detecta cualquier anomalía de serialización
- ❌ Es una decisión global de transacción, no por recurso: obliga a manejar `SerializationFailure` y reintentos en toda transacción del sistema
- ❌ Penaliza operaciones que no tienen nada que ver con stock

### Gema `with_advisory_lock`

- ✅ Resuelve el mismo problema, probada en producción por otros proyectos
- ❌ Es una dependencia más para lo que termina siendo ~40 líneas de código propio
- ❌ Para un trabajo final interesa que la clave, el timeout y el manejo de errores queden explícitos y auditables en el propio código del proyecto, no ocultos en una gema

## Consecuencias

- ✅ Sin infraestructura nueva: PostgreSQL ya es parte del stack y ya es la fuente de verdad del stock
- ✅ No hay locks huérfanos que limpiar: el motor los libera solo, al terminar la transacción (commit o rollback)
- ✅ El PORO es explícito y auditable: clave, timeout y manejo de errores están a la vista en ~40 líneas
- ⚠️ El aislamiento entre tenants depende de que `Current.company_id` esté seteado — un olvido se convierte en un `ArgumentError` ruidoso en vez de un lock mal aislado
- ⚠️ La granularidad por producto serializa de más cuando una empresa escribe stock del mismo producto en depósitos distintos al mismo tiempo
- ⚠️ Las escrituras batch (`update_all`, `upsert_all`, SQL crudo) se saltean el PORO por completo — por eso existe el `CHECK` de la base como red de seguridad independiente
- ⚠️ Los specs de concurrencia necesitan desactivar el envoltorio transaccional de RSpec (`use_transactional_tests = false`): si no, las dos "conexiones" que se quieren probar en paralelo viven dentro de la misma transacción de test y nunca compiten de verdad por el lock
