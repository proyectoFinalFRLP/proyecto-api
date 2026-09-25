# ADR-015: Convención de respuesta de la API

**Fecha:** 2026-09-23  
**Estado:** Aceptado

---

## Contexto

La API creció una card por vez y cada una eligió cómo devolver su respuesta. Nadie escribió la regla, así que no había una: había cuatro formas conviviendo.

| Forma                       | Endpoints                                                            |
| --------------------------- | -------------------------------------------------------------------- |
| `{ "data": [...], "meta" }` | `GET /products`, `/orders`, `/shipments`, `/failed-events`             |
| `{ "data": [...] }`         | `/warehouses`, `/stock-transfers`, `/products/:id/mappings`, `/quotes` |
| `[...]` — array pelado      | `GET /integrations`                                                    |
| objeto pelado               | todos los `show`, `create` y `update`                                  |

El costo no lo paga el backend, lo paga el consumidor. El frontend ya lo tenía anotado como trampa en `src/features/inventory/api.ts`: «`index` envuelve en `{ data: [...] }`, pero `show` y `update` devuelven el objeto pelado». Un comentario así es la señal de que la regla no existe: si existiera, no haría falta recordarla por endpoint.

Mientras hubo una sola pantalla consumiendo la API la inconsistencia era barata. Con el panel, el catálogo, órdenes, envíos y reportes leyendo de acá, cada pantalla nueva tiene que redescubrir de qué forma contesta cada endpoint.

## Decisión

**Una colección viaja envuelta. Un recurso solo viaja pelado.**

```
GET    /api/v1/products        → { "data": [ {...}, {...} ], "meta": { page, per_page, total } }
GET    /api/v1/warehouses      → { "data": [ {...}, {...} ] }
GET    /api/v1/integrations    → { "data": [ {...}, {...} ] }

GET    /api/v1/products/:id    → { "id": 1, "sku": "...", ... }
POST   /api/v1/products        → { "id": 1, "sku": "...", ... }
PUT    /api/v1/products/:id    → { "id": 1, "sku": "...", ... }

cualquier error                → { "error": "..." }
```

`error` es una sola clave y un solo string, y **siempre está**. Puede venir acompañado de datos para recuperarse: el 409 del locking optimista agrega `current_version`, que es lo que el frontend necesita para reintentar. Lo que no se admite es otra clave en su lugar —`errors` en plural, un array, un objeto por campo—, porque entonces el consumidor tiene que probar dos formas.

```
```

`meta` aparece sólo si el listado pagina, y es siempre `page`, `per_page` y `total`, contando el scope **ya filtrado**.

Hubo que cambiar dos endpoints. `integrations#index`, que devolvía un array en la raíz, y `auth/register`, que respondía sus dos errores como `{ "errors": [...] }` —plural y array—. El registro no lo detectó la primera pasada porque el spec de contrato no lo cubría; ahora sí.

## Alternativas consideradas

**Envolver también los recursos solos** (`{ "data": { ... } }` en `show`, `create` y `update`). Es la regla más simple de enunciar —una sola, sin excepciones— y deja lugar para agregarle `meta` a un recurso individual el día que haga falta.

Se descartó por lo que costaba **ahora**, no por lo que vale: son diez lugares del frontend, repartidos en cuatro archivos de frontera, y cada uno hay que cambiarlo y volver a probarlo para ganar uniformidad en endpoints que hoy nadie confunde. La URL ya separa los dos casos —`/products` contra `/products/:id`—, así que lo que se compra con esos diez cambios es que la regla se enuncie sin la segunda mitad.

_(La primera versión de este ADR agregaba que dos de esos archivos estaban siendo editados en las ramas vivas de TESIS-58 y TESIS-61. Las dos se mergearon el 24/09, así que ese motivo ya no corre; el costo de los diez lugares, sí.)_

La puerta queda abierta: pasar de esta convención a la otra es aditivo del lado del backend —envolver lo que hoy va pelado— y el día que se haga, este ADR se reemplaza en vez de discutirse de nuevo.

**Dejar la inconsistencia documentada** en vez de corregirla. Se descartó porque un array en la raíz no es sólo una forma distinta: no admite agregarle `meta` sin romper a quien lo consume. Si `integrations` pagina algún día —y TESIS-108 lo evalúa— habría que romperlo igual, con más consumidores encima.

## Consecuencias

**A favor**

- La regla se enuncia en una línea y no tiene excepciones que justificar.
- Ninguna colección queda con un array en la raíz, así que cualquiera puede empezar a paginar sin romper su contrato. Es la precondición de TESIS-108.
- El comentario-trampa del frontend se borra: lo que explicaba ya no pasa.
- `spec/requests/api/v1/api_contract_spec.rb` (TESIS-90) fija las tres formas **sobre los endpoints que enumera**, hoy incluido el registro. La lista está escrita a mano: un endpoint nuevo con otra forma no rompe nada hasta que se lo agrega ahí. Recorrer todas las rutas sería otra card; mientras tanto, sumar el endpoint al spec es parte de agregarlo.

**En contra**

- El consumidor sigue teniendo que saber si lo que pidió es una colección o un recurso. No es gratis, pero es una distinción que ya existe en la URL: `/products` contra `/products/:id`.
- `GET /api/v1/integrations` cambia de forma. Es un cambio que rompe, y va con su lado del frontend en el mismo momento.

## Referencias

- TESIS-107 — la card que pedía definir la convención
- TESIS-108 — paginación consistente, que necesita que ninguna colección esté pelada
- TESIS-90 — `api_contract_spec.rb`, donde la regla queda fijada de forma ejecutable
