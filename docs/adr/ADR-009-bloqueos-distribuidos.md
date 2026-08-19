# ADR-009: Bloqueos distribuidos para el control de concurrencia de stock

**Fecha:** 2026-08-10  
**Estado:** Aceptado

---

## Contexto

Toda mutación de stock tiene que quedar serializada por producto a través de todos los procesos concurrentes que pueden tocarla: varios workers de Puma atendiendo requests HTTP, varios workers de Solid Queue procesando jobs y, eventualmente, varias instancias desplegadas del mismo proceso. Un `Mutex` de Ruby no resuelve nada acá: es un lock por proceso, y el problema es entre procesos — y eventualmente entre instancias desplegadas.

**Qué problema resuelve este ADR y cuál no.** La operación que necesita exclusión mutua es la de *read-modify-write*: leer la cantidad actual, calcular la nueva a partir de ella y escribirla. Ese es el descuento de stock al confirmar una orden (TESIS-42/44). El ABM de productos de hoy **no** es ese caso: `Products::UpdateProduct` recibe la cantidad absoluta desde el request y la asigna, así que dos ediciones concurrentes se pisan y serializar no cambia cuál gana. Eso es un *lost update* y pide **detección**, no exclusión: locking optimista (`lock_version`) o un `If-Match`/ETag que rechace la escritura basada en datos viejos con un 409. Queda fuera del alcance de este ADR porque implica cambiar el contrato de la API y coordinarlo con el frontend.

Lo que sí aporta el lock en el ABM de hoy es convertir la carrera de creación de filas en un 409 limpio. Sin lock, dos escrituras concurrentes que crean la misma fila de `stocks` no producen filas duplicadas — el índice único `index_stocks_on_product_id_and_warehouse_id` ya lo impide desde TESIS-32 — pero la perdedora muere con `RecordNotUnique`. El lock evita llegar ahí; el índice sigue siendo la garantía de fondo.

## Decisión

Se adoptan **advisory locks de PostgreSQL a nivel de transacción**, encapsulados en un PORO: `Catalog::WithStockLock` (`app/poros/catalog/with_stock_lock.rb`). Vive en el dominio `catalog` y no en `poros/shared/` porque la "Regla de Dos" de [`feature-structure.md`](../guidelines/feature-structure.md) manda mover a `shared/` *cuando un segundo dominio ya necesita* la lógica, no cuando se prevé que la va a necesitar. Hoy el único consumidor es `catalog`. Cuando `orders` descuente stock al confirmar una orden, se mueve.

Interfaz:

```ruby
Catalog::WithStockLock.new(product_id: product.id).call do
  # sección crítica: escrituras de stock
end

# En requests HTTP interactivos conviene fallar rápido en vez de colgar un thread de Puma:
Catalog::WithStockLock.new(product_id: product.id, wait: false).call { ... }
```

**`pg_advisory_xact_lock` y no `pg_advisory_lock` (TESIS-38).** El lock se toma a nivel de transacción y el motor lo libera solo, en el `COMMIT` o el `ROLLBACK`. El lock a nivel de sesión (`pg_advisory_lock` / `pg_advisory_unlock`) exige que el propio código libere el lock explícitamente: un proceso que muere entre el `lock` y el `unlock` lo deja tomado hasta que se cierre la conexión, y con un pool de conexiones esa conexión puede seguir viva horas. Con el lock transaccional no hay locks huérfanos que barrer.

**Clave del lock (TESIS-38).** Es un entero de 64 bits derivado por SHA-256 de `"#{namespace}:#{product_id}"`, con `namespace = 'stock'`. **No lleva `company_id`**: `products.id` es una PK global, así que dos empresas nunca comparten un `product_id` y el tenant no agregaría ningún aislamiento que el `product_id` no dé solo. El namespace deja lugar para futuros recursos bloqueables (por ejemplo, un lock sobre la confirmación de una orden en `orders`) sin colisionar con las claves de stock.

**El lock no depende del tenant activo (TESIS-38).** Como la clave sale sólo del `product_id`, el PORO se puede usar desde una consola, una tarea de rake o un bloque `unscoped`, donde no hay `Current.company_id`. El aislamiento entre empresas lo sigue dando el `default_scope` de `CompanyScoped` sobre las queries, que es donde corresponde (ver [ADR-003](ADR-003-multitenancy.md)); la clave del lock no es un mecanismo de multi-tenancy.

**Granularidad por producto, no por producto + depósito (TESIS-38).** Un update del ABM de productos puede tocar varias filas de `stocks` del mismo producto en un solo request, y algunas de esas filas todavía pueden no existir. Bloquear por depósito hubiera exigido tomar N locks en un orden estable para evitar deadlocks entre transacciones que actualizan los mismos depósitos en orden distinto. Se asume el costo: si una empresa mueve stock del mismo producto en depósitos distintos al mismo tiempo, esas escrituras se serializan de más aunque no compitan por la misma fila.

**`lock_timeout` configurable (TESIS-38).** El PORO ejecuta `SET LOCAL lock_timeout` antes de tomar el lock (3000 ms por default): una espera no puede bloquear indefinidamente un worker de Puma o de Solid Queue. Vencido el timeout, se levanta `Catalog::LockTimeoutError`, que `ApplicationController` mapea a **409 Conflict**.

**`wait: true` vs `wait: false` (TESIS-38).** El PORO expone las dos variantes que ofrece PostgreSQL: `pg_advisory_xact_lock` (espera hasta el `lock_timeout`, es el comportamiento con `wait: true`, el default) y `pg_try_advisory_xact_lock` (no espera, devuelve al instante si el lock está tomado, `wait: false`). Un job de background puede permitirse esperar y confiar en el reintento de Active Job si aun así falla; un request HTTP interactivo no debería dejar un thread de Puma colgado esperando un lock — conviene fallar rápido con 409 y que el cliente reintente.

**Sin `SELECT ... FOR UPDATE` adentro (TESIS-38).** Una versión anterior de este ADR justificaba un `Stock#lock!` dentro del advisory lock, para releer la fila con el valor vigente en la base. No aporta nada: la línea siguiente pisa `quantity` con el valor del request, así que el valor releído se descarta sin leerse. Y la premisa tampoco era cierta — `find_or_initialize_by` emite su propio SELECT, así que el objeto nunca llegaba desactualizado. Se sacó. Cuando exista el read-modify-write de `orders`, ese caso sí va a leer la cantidad antes de escribirla, y ahí el advisory lock ya garantiza la exclusividad sin necesidad de un `FOR UPDATE` por fila.

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
- ❌ Obliga a agregar la columna `lock_version` y a cambiar el contrato de la API (`stocks: [{ warehouse_id, quantity }]` no tiene dónde llevar la versión), lo que hay que coordinar con el frontend
- ⚠️ **No es una alternativa a este ADR, es un complemento**: resuelve el lost update de dos ediciones humanas del ABM, que el advisory lock no resuelve. Queda pendiente como card propia; ver la sección Contexto

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
- ⚠️ El lock ordena escrituras, no detecta ediciones concurrentes: el lost update del ABM sigue abierto hasta que se implemente el locking optimista
- ⚠️ La granularidad por producto serializa de más cuando una empresa escribe stock del mismo producto en depósitos distintos al mismo tiempo
- ⚠️ Las escrituras batch (`update_all`, `upsert_all`, SQL crudo) se saltean el PORO por completo — por eso existe el `CHECK` de la base como red de seguridad independiente
- ⚠️ Los specs de concurrencia necesitan desactivar el envoltorio transaccional de RSpec (`use_transactional_tests = false`): si no, las dos "conexiones" que se quieren probar en paralelo viven dentro de la misma transacción de test y nunca compiten de verdad por el lock
