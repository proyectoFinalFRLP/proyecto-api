# ADR-022: OCA e-Pak con el adaptador genérico (form, XML y etiqueta a pedido)

**Fecha:** 2026-10-16  
**Estado:** Aceptado

---

## Contexto

El criterio de aceptación del proyecto (E4b V2 §2.6) pide al menos un courier funcionando de punta a punta contra un entorno real o de prueba. Shopify ya lo cumplía del lado del e-commerce ([ADR-018](ADR-018-conexion-con-proveedores-reales.md)); del lado logístico, Andreani y Correo Argentino sólo existían como plantillas probadas con WebMock.

El courier elegido es **OCA e-Pak**, porque publica un entorno de prueba abierto (`integraciones.ocadev.com.ar`) con una cuenta de prueba documentada para desarrolladores. Su API no se parece a nada de lo que el motor sabía hablar:

- Es un servicio **ASMX de .NET**: cada operación es `POST {base}/{Método}` con los parámetros como `application/x-www-form-urlencoded`. Todos son obligatorios: si falta uno contesta **HTTP 500** con un texto plano (`Missing parameter: Operativa.`).
- Contesta **XML**, casi siempre un **DataSet** serializado (`<DataSet><xs:schema/><diffgr:diffgram><NewDataSet><Table>...`). Algunas operaciones contestan un `<string>` con el dato adentro (la etiqueta, un PDF en base64).
- Los **errores de negocio llegan con HTTP 200**: una fila `<Table1><Error>` en la cotización, `<Errores><Error><Descripcion>` en el alta.
- La cuenta (`usr`, `psw`) viaja **como parámetro**, no como header.
- El alta (`IngresoORMultiplesRetiros_v2`) recibe el envío como **un XML dentro de un parámetro** (`xml_Datos`), con largos máximos por campo (calle 30, número 5, nombre 30...).
- La etiqueta **no viene en el alta**: se pide aparte, con la orden de retiro y el número de envío.
- El seguimiento (`GetEnvioEstadoActual`) contesta el estado como **texto libre** (`En proceso de Retiro`, `Visita - Domicilio Cerrado`, `Estado de Visita ONLINE (Entregado)`) y la fecha **sin hora** (`16/10/2026`).

El principio de TESIS-31 sigue vigente: la diferencia entre proveedores vive en datos, no en código ([ADR-018](ADR-018-conexion-con-proveedores-reales.md), «Una clase Ruby por proveedor»). La pregunta era qué capacidades **genéricas** le faltaban al adaptador para que OCA fuera sólo un juego de plantillas.

## Decisión

OCA e-Pak se integra con **cinco plantillas** (`db/seeds/oca.rb`) sobre capacidades nuevas del adaptador que no saben nada de OCA. No hay una línea de `app/` que diga «OCA».

| Plantilla | Operación de OCA | Rol |
|---|---|---|
| `OCA e-Pak - Cotización` | `Tarifar_Envio_Corporativo` | Cotizar (`quote_service` de la de despacho) |
| `OCA e-Pak` | `IngresoORMultiplesRetiros_v2` | Despachar: la que se conecta |
| `OCA e-Pak - Etiqueta` | `GetPdfDeEtiquetasPorOrdenOrNumeroEnvio` | Hija `label` |
| `OCA e-Pak - Conexión` | `GetOperativasByUsuario` | Hija `connection_test` |
| `OCA e-Pak - Seguimiento` | `GetEnvioEstadoActual` | `tracking_service` de la de despacho (ADR-014) |

### `request_format: form`

El resultado del `request_mapper` se manda como `application/x-www-form-urlencoded`: en el body de un `POST`, en el query string de un `GET`. Las claves son **planas**: `a.b` es el nombre del parámetro, no un anidamiento (un form no anida). Los números van con punto decimal y sin notación científica (`2.5`, no `0.25e1`), y un decimal entero sin decimales (`15000`, no `15000.0`), que es lo que acepta un servicio .NET.

### `response_format: xml`, columna y no Content-Type

Columna nueva `services.response_format` (`json` por defecto, `xml`), con CHECK en la base. Se descartó deducirlo del `Content-Type` de la respuesta:

- La plantilla ya declara todo lo demás de su transporte (`request_format`, `auth_strategy`): el formato de la respuesta es del mismo tipo de dato.
- Un proveedor que miente el `Content-Type` (`text/html` para un JSON, `text/plain` para un XML) rompería la lectura sin que la plantilla pudiera corregirlo.
- Es determinista en los specs: WebMock no tiene que acordarse de un header para que el adaptador elija el parser.

La respuesta XML se convierte a un Hash (`Integrations::ParseXmlResponse`) y desde ahí todo es igual que con JSON: mappers, `error_path`, `dig_path`. Las reglas, pocas y genéricas:

- Se descartan los namespaces y el esquema del DataSet (`xs:schema`).
- `diffgram` y su hijo (`NewDataSet`, `Resultado`, `Errores`) son envoltorios: sus filas quedan bajo la raíz. Un DataSet se lee `Table.0.Total`.
- Hermanos con el mismo nombre son un Array; una sola fila es un Hash. Como un XML no distingue «una fila» de «una lista con una fila», **`dig_path` acepta el índice `0` (y `-1`) sobre un Hash suelto**: `Table.0.Total` sirve para las dos.
- Un elemento sin hijos es su texto sin los espacios del borde (SQL Server rellena los campos de ancho fijo), o `nil` si está vacío. Si el texto es a su vez XML, se convierte.
- La raíz no aparece como clave, salvo que sea un texto suelto: `<string>JVBER...</string>` da `{ "string" => "JVBER..." }`.
- Los atributos se ignoran (en un DataSet son metadatos de la fila).

El parseo es **estricto** (un body que no es XML es un error del proveedor, como un JSON roto) y no resuelve entidades externas: Nokogiri no carga DTDs ni sale a la red por defecto, así que una respuesta maliciosa no puede leer archivos (XXE).

### Credenciales como parámetros y `auth_strategy: none`

- El `request_mapper` acepta `credentials.<clave>` como fuente, igual que `settings.<clave>`. Se resuelve **dentro** del adaptador, al armar el request: el `payload` que viaja en `AdapterExecutionError`, en los logs y en la DLQ (`failed_events.payload`) es el interno, que nunca tuvo el secreto. Un payload no puede inyectar un secreto: `credentials.` se lee sólo de la integración.
- `auth_strategy: none` no manda headers de autenticación. Sin ella, `bearer` (el default) mandaba **cada clave de `credentials` como header literal**: `usr` y `psw` habrían viajado también en los headers de todos los requests.

### Valores armados: literales, filtros y `{{template:body}}`

Lo mínimo para construir lo que OCA espera, sin convertirlo en un motor de plantillas (no hay condicionales ni bucles):

- `literal:<texto>` es un valor fijo (`literal:true`, `literal:` para un parámetro obligatorio que va vacío).
- Las variables `{{x}}` aceptan **filtros** encadenados: `default:X`, `truncate:N`, `date:FORMATO` (con `today` y `now`), `ascii` (sin tildes ni eñes), `raw` y `required`. Un filtro desconocido es un error, no se ignora, y `Service` no deja guardar una plantilla que lo use: un tipeo en Avo aparece al guardar, no en el primer despacho.
- `required` es para el dato que el proveedor necesita y que no se puede inventar con un `default`. Si falta, el pedido no sale: el adaptador lo rechaza (`rejected?`) con el nombre del dato, y el despacho responde 422 con ese motivo.
- `{{template:body}}` en el `request_mapper` arma el `body_template` de la plantilla y lo manda como el valor de ese parámetro: es el `xml_Datos` de OCA. En el body template **cada valor se escapa para XML** (un `&` en un nombre no rompe el documento) y una variable sin valor queda vacía (los atributos opcionales, como el piso). En un valor suelto del `request_mapper`, en cambio, una variable sin valor hace que la entrada no se mande, como hasta ahora.
- `ascii` existe porque el entorno de prueba de OCA guarda un nombre con tildes con espacios o `?` en su lugar (verificado con `UTF-8` y con referencias numéricas). Las plantillas de OCA lo aplican a nombres, calles y localidades.

### Errores de negocio con HTTP 200

`error_path` acepta **varias rutas separadas por coma** (OCA informa un alta rechazada en `Error` y un bulto rechazado en `DetalleRechazos.0.Motivo`), lee el Hash ya convertido, y un error de una sola columna se describe por su valor (`Usuario o contraseña incorrectos`) y no como JSON.

El error sale marcado como **rechazo** (`AdapterExecutionError#rejected?`). El despacho lo responde **422** con el motivo, igual que un 4xx del proveedor: el usuario puede corregir algo (el código postal, la cuenta). Un HTTP 500 —el `Missing parameter` de una plantilla mal armada—, un timeout o un body ilegible siguen siendo **502**.

«Probar conexión» además falla si la respuesta no trae **nada** de lo que la plantilla mapea: OCA contesta una contraseña equivocada con un DataSet vacío y HTTP 200.

### `shipments.external_reference`

El id con el que el courier nombra el despacho, además del número de seguimiento. En OCA es la **orden de retiro** (no el `CodigoOperacion` del resumen, que es el id del lote). La plantilla de despacho lo mapea a `external_reference`; `ConfirmDispatch` lo guarda si viene (es opcional, como la URL de la etiqueta). Viaja en el payload de la etiqueta y del seguimiento, porque OCA pide los dos números.

### Etiqueta a pedido: `GET /api/v1/shipments/:id/label`

Los couriers que devuelven la URL del PDF al despachar siguen igual (`shipping_label_url`). Los que la emiten con otra llamada declaran una plantilla hija `label` en la de despacho, que mapea el documento en base64 a `label_pdf` (`Shipments::FetchLabel`):

| Situación | Respuesta |
|---|---|
| El courier tiene plantilla `label` | **200** `application/pdf`, `inline`, `etiqueta-<tracking>.pdf` |
| No hay plantilla pero sí `shipping_label_url` | **302** a esa URL |
| El envío no se despachó, o su courier no tiene ninguna de las dos | **404** `{ error }` |
| El courier contesta otra cosa que un PDF (OCA: «No se encontraron etiquetas...») | **502** `{ error }` con el texto |
| El courier falla | 422 / 502, con las mismas reglas del despacho |

Se autoriza con `ShipmentPolicy#label?` (el mismo permiso que ver el envío), y un envío de otra empresa es 404. Los serializers de envío exponen `label_available`, que **no consulta al courier**: es `true` si el envío tiene número de seguimiento y su courier declara la plantilla `label`, o si tiene `shipping_label_url`.

No se guarda el PDF: se pide cada vez. Guardarlo exigía un almacenamiento de archivos que el proyecto no tiene, y la etiqueta del courier es la fuente de verdad (si la reimprime con otro formato, se ve el nuevo).

Es una llamada **sincrónica** dentro del request, como la cotización y el despacho (`docs/guidelines/architecture.md` §7.4). No es un cuarto caso de la misma especie: es la **descarga de un documento** que el usuario pidió para imprimir, una sola lectura sin efectos en el proveedor, y encolarla no tiene sentido (no hay nada que notificar después). Corre con su propio timeout (4 s de apertura, 8 s de lectura: armar el PDF le toma a OCA alrededor de 1 s).

### Seguimiento: estados por prefijo y fechas sin hora

- El `response_value_mapper` busca primero la clave exacta (lo de siempre); si no está, **sin distinguir mayúsculas, tildes ni espacios repetidos**; y por último las claves que terminan en `*` como **prefijos**, ganando el más largo (`Estado de Visita ONLINE (Entregado)*` antes que `Estado de Visita ONLINE*`). Es lo que necesita un courier que agrega un detalle al estado (`En proceso de Retiro - Suc: ...`).
- `answers_tracking?` reconoce también la plantilla que manda el número de seguimiento **como parámetro** (`numeroEnvio` → `tracking_number`), no sólo en la URI.
- Una fecha `dd/MM/yyyy` se lee explícita (no se deja que `Time.zone.parse` adivine el orden). Con hora, es un momento. **Sin hora**, viaja como `occurred_on`: el evento se registra al final de ese día, o *ahora* si el día es hoy, y el duplicado se mira por el último estado. En la consulta periódica, que contesta el estado **actual**, además nunca queda antes del último evento del envío: sin esto el primer estado del día (`En proceso de Retiro`, mismo día que el despacho) quedaba a las 00:00, antes de «Etiqueta generada», y se descartaba como desordenado. Un push con un día anterior al del último evento, en cambio, se descarta como desordenado.
- **El estado del envío sólo avanza**, en el orden de `Shipment::STATUSES`. Con fechas sin hora el orden de los eventos no alcanza: OCA informa «En proceso de Admision» (`ready_to_ship`) después de «Retirado» (`in_transit`). Un estado traducido que queda atrás se registra en la bitácora como informativo, con el estado que ya tenía el envío.

### Cotización y alta manual

La cotización de OCA usa el mismo flujo de 4 s en paralelo (ADR-016). Medido contra el entorno de prueba: **0,08–0,45 s**, así que no hizo falta un timeout por plantilla. La cotización de OCA pide CPs, peso, volumen, valor declarado, CUIT y operativa: no pide localidad ni provincia.

El peso y las medidas del bulto **no se inventan**. `package_weight_kg` es nil si algún producto no tiene peso, y el bulto consolidado no tiene medidas si a algún producto le falta una. Las plantillas de OCA los piden con `required`: sin ellos OCA no aparece entre las opciones de la cotización, y el despacho responde 422 con el dato que falta. Antes se cotizaba un paquete de 0 kg y se pedía el retiro de una caja de 1 cm de lado. `total_weight` sigue sumando cero por el producto sin peso: es como la mapean Andreani y Correo.

`POST /api/v1/quotes` (el borrador del alta manual) acepta tres parámetros **opcionales** nuevos: `destination_city`, `destination_province` y `declared_value` (número ≥ 0; si no, 400). Los dos primeros no los usa OCA, pero el `CourierPayload` ya los tiene y un courier que los pida los recibe. Sin `declared_value`, OCA cotiza con 0 (la plantilla dice `{{declared_value|default:0}}`).

### Seeds, conexión y demo

Los seeds cargan las plantillas, que apuntan al entorno de prueba de OCA, nunca al productivo. **En desarrollo**, además, Norte queda conectada con la cuenta de prueba pública de OCA (`OcaSeeds.connect_demo!`), así el flujo completo anda apenas se siembra la base; nunca pisa una integración que ya existe. **En producción** sólo se siembran las plantillas. Otra cuenta se carga con las tareas de desarrollo, con el mismo patrón que Shopify (TESIS-138, `lib/tasks/integrations.rake`):

- `bin/rails "integrations:oca:connect[slug]"` lee `OCA_<SLUG>_USR`, `_PSW`, `_CUIT`, `_NROCUENTA`, `_OPERATIVA`, `_CENTROCOSTO` (y opcionales `_IDFRANJAHORARIA`, `_EMAIL`) del entorno o de `.env`, y crea la integración que despacha y la que cotiza con `Integrations::UpsertIntegration`, que valida los campos declarados y cifra las credenciales.
- `integrations:oca:test[slug]` prueba la cuenta.
- `integrations:oca:smoke[slug]` recorre cotizar → despachar → etiqueta → seguimiento contra el entorno de prueba, por los mismos casos de uso de la API, con una venta y un destinatario inventados. No corre en CI (sale a internet y crea una orden de retiro) y se niega a correr si la plantilla no apunta al host de prueba.

La lectura de `.env` se extrajo a `DevEnv` (`lib/tasks/dev_env.rake`), compartido con las tareas de Shopify. `.env.example` trae, comentados, los valores de la cuenta de prueba pública de OCA (`test@oca.com.ar`, CUIT `30-53625919-4`, cuenta `111757/001`, operativa puerta a puerta `64665`, centro de costo `1`): son públicos, están en la documentación de OCA para desarrolladores.

Fuera de desarrollo no se siembra la integración con esa cuenta: los seeds corren también en el entorno desplegado (ADR-021), y una cuenta de un proveedor no se siembra, se conecta.

Las credenciales que se cargan desde Avo viajan como `credentials__<clave>`, con la clave que decide el proveedor (`usr` y `psw` en OCA). `filter_parameters` filtra `credentials` entero, para que ninguna termine en la línea `Parameters:` del log.

## Alternativas consideradas

### Un cliente Ruby para OCA (`Couriers::Oca::Client`)

Más rápido de escribir y más fácil de leer para quien conoce OCA. Se descartó por el mismo motivo que en ADR-018: rompe el principio de TESIS-31, que es lo que el proyecto defiende («plug and play, sin desarrollo a medida»). El siguiente courier SOAP/ASMX (o el siguiente que conteste XML) sería otra clase. Con este diseño, cada capacidad nueva sirve para cualquiera.

### SOAP en lugar de form

ASMX acepta las dos cosas. SOAP exige armar el sobre, el `SOAPAction` y leer la respuesta dentro de `soap:Body`: más transporte para el mismo resultado. El form es lo que OCA documenta como uso habitual y lo que el resto de los servicios ASMX aceptan.

### Un motor de plantillas completo (Liquid, ERB)

Resolvía el XML del alta con bucles y condicionales. Se descartó porque una plantilla editable desde el backoffice con un lenguaje de propósito general es una superficie de ataque (ERB ejecuta Ruby) o una dependencia nueva (Liquid), para un caso que se resuelve con variables y cinco filtros.

### Guardar el PDF de la etiqueta

Pedirlo al despachar y guardarlo evitaba la llamada al imprimir. Exige almacenamiento de archivos (Active Storage con un servicio en el despliegue), y deja una copia que puede quedar vieja. Se puede sumar sin cambiar el contrato: el endpoint seguiría siendo el mismo.

## Consecuencias

- ✅ OCA e-Pak cotiza, despacha, emite la etiqueta, se sigue y prueba su conexión contra su entorno de prueba real, sólo con plantillas
- ✅ Las capacidades nuevas son genéricas: form, XML, credenciales como parámetros, literales, filtros, body template, varias rutas de error, estados por prefijo, fechas sin hora, etiqueta a pedido
- ✅ Andreani, Correo Argentino y Shopify siguen igual: los defaults (`json`, `bearer`) no cambiaron, y la búsqueda exacta en el `response_value_mapper` va primero
- ✅ Un rechazo de negocio del courier ahora es 422 con su motivo, aunque llegue con HTTP 200
- ⚠️ **Un solo bulto**: el consolidado de TESIS-185. OCA acepta varios `<paquete>`, pero el motor no sabe repetir un fragmento de plantilla
- ⚠️ **Sólo puerta a puerta**: la operativa de la demo. Retiro en sucursal o entrega en sucursal (`idci`) piden otra operativa y elegir la sucursal, que el alta manual no ofrece
- ⚠️ **Sin anulación**: `AnularOrdenGenerada` existe, pero el sistema no tiene cancelación de envíos
- ⚠️ **Sin push**: OCA no empuja el tracking; se le pregunta cada 30 minutos (ADR-014)
- ⚠️ La fecha del retiro es **hoy** (`{{today|date:%Y%m%d}}`), y el sistema corre en UTC: un despacho después de las 21 (hora argentina) pide el retiro para el día siguiente. Resolverlo bien es definir `config.time_zone`, que toca todas las fechas de la app y es otra card
- ⚠️ **El despacho no es idempotente**: si OCA crea la orden de retiro y la respuesta tarda más que el timeout, el envío queda pendiente y reintentarlo pide otro retiro. Si dos requests despachan a la vez, el que pierde descarta su orden de retiro y la deja en el log con nivel error, para anularla a mano. El remito lleva el momento del alta (`OS-<id>-<aammddhhmmss>`), porque la cuenta de prueba es una sola y `OS-1` se repite en cada base sembrada
- ⚠️ Las devoluciones y anulaciones de OCA no están mapeadas (el dominio no tiene esos estados): quedan como eventos informativos y el envío sigue en curso, así que la consulta periódica lo sigue preguntando
- ⚠️ Las horas de OCA están en hora argentina y el sistema corre en UTC; con fechas sin hora, el día se toma tal cual. Un estado reportado entre las 21 y las 24 puede quedar con el día anterior
- ⚠️ Los nombres con tildes se mandan sin tildes (`ascii`): OCA no los guarda bien de ninguna otra forma
- ⚠️ La cuenta de prueba es pública y compartida: cualquiera puede ver las órdenes de retiro creadas en el entorno de prueba. Los datos de la demo son inventados
- ⚠️ La etiqueta se pide al courier cada vez que se abre: si OCA está caído, no se puede reimprimir

## Referencias

- [ADR-012](ADR-012-creacion-de-envios.md) y [ADR-016](ADR-016-cotizacion-del-alta-manual.md): el despacho y la cotización que OCA usa
- [ADR-014](ADR-014-pull-tracking-de-couriers.md): la consulta periódica de tracking
- [ADR-018](ADR-018-conexion-con-proveedores-reales.md): plantillas de operación, `credential_fields` / `setting_fields`, `error_path`
- `docs/guidelines/architecture.md` §7.4: las llamadas sincrónicas a proveedores
- OCA e-Pak para desarrolladores: https://developers.oca.com.ar/epak.html (cuenta de prueba) y el WSDL de `Oep_TrackEPak.asmx`
