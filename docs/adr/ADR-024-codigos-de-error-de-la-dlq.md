# ADR-024: Códigos de soporte para los errores de la Dead Letter Queue

**Fecha:** 2026-10-26  
**Estado:** Aceptado

---

## Contexto

La cola de eventos fallidos ([ADR-008](ADR-008-dead-letter-queue.md)) le mostraba al operador el `last_error` tal cual lo guarda `Webhooks::FailureDetails`: `Clase: mensaje`, en inglés y con el nombre de la excepción delante (`Integrations::AdapterExecutionError: Andreani responded with HTTP 503`). Sirve para quien diagnostica con el código abierto, pero el operador no puede hacer nada con eso, y dictárselo a soporte es copiar un texto que cambia cada vez que alguien reescribe un mensaje.

Además, la clase sola no distingue los fallos más comunes: todo lo que sale del `HttpAdapter` es `AdapterExecutionError`, sea un 401, un timeout o una respuesta ilegible.

## Decisión

**Cada evento fallido guarda un código de soporte estable** (`failed_events.error_code`), y la API lo devuelve junto con la causa en castellano.

```
excepción ──> Webhooks::ErrorCatalog.code_for(error) ──> failed_events.error_code   (INT-005)
                                                                │
GET /api/v1/failed-events  ──>  error_code     "INT-005"        │
                                error_message  "El proveedor no está disponible"  (message_for)
                                last_error     "Integrations::AdapterExecutionError: …"
```

| Pieza                         | Rol                                                                              |
| ----------------------------- | -------------------------------------------------------------------------------- |
| `Webhooks::ErrorCatalog`      | Los códigos, sus mensajes y la traducción de una excepción a su código           |
| `Webhooks::FailureDetails`    | Guarda `error_code` con el resto del diagnóstico, al registrar y en cada reintento |
| `Webhooks::RetryFailedEvent`  | Al resolverse el evento borra el código: ya no hay un error actual               |
| `FailedEventSerializer`       | Expone `error_code` y `error_message`, los dos `null` cuando no hay error        |

### Los códigos

Un prefijo por dominio y un número: `GEN` (motor), `INT` (proveedores e integraciones), `ORD` (ventas), `TRK` (seguimiento), `STK` (stock). La tabla completa vive en `Webhooks::ErrorCatalog::MESSAGES`.

**Un código no se renumera ni se reutiliza nunca.** Uno que deja de usarse queda retirado y una causa nueva lleva un número nuevo: así una fila vieja, un reporte o lo que el operador anotó siguen significando lo mismo. Un código que el catálogo no conoce se lee como `GEN-000` («Error inesperado»), nunca como una causa en blanco.

### Cómo se elige el código

- **Por clase**, recorriendo los ancestros (`BY_CLASS`): una subclase sin entrada propia hereda el código del padre.
- **Un `AdapterExecutionError` se mira por dentro**, porque la clase no dice nada:
  1. el status con el que contestó el proveedor (401/403, 404, 429, 5xx, otro 4xx);
  2. si no contestó, la excepción que el adapter envolvió (`cause`): timeout, red, respuesta ilegible, plantilla rota;
  3. si el proveedor rechazó el pedido con un 200 (`rejected?`), `INT-008`; si no, `INT-001`.
- `Integrations::MissingValueError` y `RenderTemplate::MissingValueError` comparten `INT-010`: es el mismo problema visto desde dos capas.

Un spec recorre todas las excepciones de `app/poros` y exige que cada una tenga código o figure en una lista de excluidas con su motivo (las que sólo levanta un controller y contesta en el momento, sin pasar nunca por la DLQ). Un error nuevo no puede llegar a la cola sin que alguien decida qué código lleva.

### Las filas que ya estaban

La migración que agrega la columna completa las existentes con un único `UPDATE … CASE` sobre `last_error` y `last_response_status`, en el mismo orden que el catálogo: status, después los textos que arma el `HttpAdapter` (la `cause` no se guardó, sólo queda en el mensaje), después la clase. Compara contra una **copia congelada** del mapa de clases y no contra la constante viva, para que correrla en otra base dé siempre lo mismo.

### `last_error` sigue en la API

El texto técnico se sigue serializando. El front lo muestra en un tooltip del detalle, no en la celda: el operador lee el código y la causa, y quien diagnostica tiene el texto completo sin abrir la base. Sacarlo obligaba a ir a la consola para cada caso que el catálogo resuelve como `GEN-000`, que son justamente los que más hace falta leer.

**Alternativas descartadas:**

- **Traducir el `last_error` en el front.** Los mensajes de las excepciones están en inglés y cambian; el front tendría que conocer las clases de Ruby, y cualquier cambio de texto rompería la traducción sin que ningún test lo note.
- **Calcular el código al serializar, sin columna.** Para los errores del adapter el código depende de la `cause`, que no se guarda: no se podría reconstruir desde `last_error` sin repetir en cada request los patrones de texto de la migración. Guardarlo además permite filtrar o contar por código.
- **Un código por clase de excepción, sin mirar adentro.** Dejaba la mitad de la cola como `INT-001`, que es lo que este cambio vino a resolver.

## Consecuencias

- ✅ El operador ve una causa que entiende y un código que le puede dar a soporte.
- ✅ Los códigos sobreviven a cambios de mensaje y de clase: el contrato es el código, no el texto.
- ⚠️ Una excepción nueva que llega a la DLQ pide su código en el catálogo; el spec de cobertura lo recuerda.
- ⚠️ Las filas anteriores se codificaron por texto: un mensaje que no responde a los patrones conocidos queda con el código de su clase o en `GEN-000`.
