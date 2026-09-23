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

`meta` aparece sólo si el listado pagina, y es siempre `page`, `per_page` y `total`, contando el scope **ya filtrado**.

El único endpoint que hubo que cambiar fue `integrations#index`, que devolvía un array en la raíz.

## Alternativas consideradas

**Envolver también los recursos solos** (`{ "data": { ... } }` en `show`, `create` y `update`). Es la regla más simple de enunciar —una sola, sin excepciones— y deja lugar para agregarle `meta` a un recurso individual el día que haga falta.

Se descartó por lo que costaba **ahora**, no por lo que vale: son diez lugares del frontend, en cuatro archivos de frontera, y dos de esos archivos son los que TESIS-58 y TESIS-61 están editando en ramas vivas. Cambiar el contrato debajo de dos PRs abiertos, para ganar uniformidad en endpoints que hoy nadie confunde, no se paga.

La puerta queda abierta: pasar de esta convención a la otra es aditivo del lado del backend —envolver lo que hoy va pelado— y el día que se haga, este ADR se reemplaza en vez de discutirse de nuevo.

**Dejar la inconsistencia documentada** en vez de corregirla. Se descartó porque un array en la raíz no es sólo una forma distinta: no admite agregarle `meta` sin romper a quien lo consume. Si `integrations` pagina algún día —y TESIS-108 lo evalúa— habría que romperlo igual, con más consumidores encima.

## Consecuencias

**A favor**

- La regla se enuncia en una línea y no tiene excepciones que justificar.
- Ninguna colección queda con un array en la raíz, así que cualquiera puede empezar a paginar sin romper su contrato. Es la precondición de TESIS-108.
- El comentario-trampa del frontend se borra: lo que explicaba ya no pasa.
- `spec/requests/api/v1/api_contract_spec.rb` (TESIS-90) fija las tres formas, así que un endpoint nuevo que invente una cuarta rompe la suite.

**En contra**

- El consumidor sigue teniendo que saber si lo que pidió es una colección o un recurso. No es gratis, pero es una distinción que ya existe en la URL: `/products` contra `/products/:id`.
- `GET /api/v1/integrations` cambia de forma. Es un cambio que rompe, y va con su lado del frontend en el mismo momento.

## Referencias

- TESIS-107 — la card que pedía definir la convención
- TESIS-108 — paginación consistente, que necesita que ninguna colección esté pelada
- TESIS-90 — `api_contract_spec.rb`, donde la regla queda fijada de forma ejecutable
