# ADR-017: Backoffice de administración de la plataforma

**Fecha:** 2026-09-25  
**Estado:** Aceptado

---

## Contexto

El backoffice (`/admin`, construido con Avo) es la consola del administrador de la plataforma: da de alta empresas, plantillas de servicios y usuarios, y ve la operación de todas las empresas. Llegó con TESIS-29 (panel de servicios) y TESIS-123 (el resto de los recursos), pero ningún ADR lo documentaba: las decisiones estaban repartidas en comentarios de `config/initializers/avo.rb`, `config/initializers/devise_jwt.rb` y `config/application.rb`.

La QA del módulo (TESIS-129) lo validó antes de integrarlo con el resto del sistema. Como el backoffice ve los datos de todas las empresas, una falla acá las expone a todas a la vez. Este ADR registra cómo está armado y cómo se cerró cada hallazgo.

## Decisión

### Autenticación propia, separada de la API

- Scope Devise `admin_user` (tabla `admin_users`), con login navegacional en `/admin/sign_in` y sesión por cookie (`_proyecto_api_session`, el cookie store de Rails).
- La API sigue stateless, con JWT (scope `user`). Ninguna credencial abre la otra puerta: un JWT de empresa en `/admin` redirige al login, y la sesión del admin en `/api/v1` responde 401 (`spec/requests/admin/api_separation_spec.rb`).
- El modo API-only de Rails saca cookies, sesión y flash. Se agregan de vuelta sólo para el backoffice (`config/application.rb`), y van **antes** de `Warden::Manager` (ver «Sesión»).

### Acceso a todas las empresas, por diseño

`config.authorization_client = nil`: el administrador ve y edita los datos de todas las empresas. No hay policies de Avo ni un scope por tenant, porque el backoffice es la herramienta del operador de la plataforma y no la de un tenant. `CompanyScoped` no filtra porque en estos requests `Current.company_id` es nil.

La consecuencia es que la seguridad del backoffice descansa entera en el login y en la sesión. Por eso tienen defensas propias.

### Login

- **Mensaje genérico.** Una password incorrecta y un email inexistente responden igual: 422 y «Invalid email or password.».
- **Mismo tiempo de respuesta.** `config.paranoid = true` en Devise. Sin él, bcrypt sólo corría cuando el email tenía cuenta, y el rechazo de un email inexistente volvía ~200 ms antes: el mensaje era idéntico, pero el tiempo decía qué emails de admin existen. La opción es global, pero hoy sólo la usa el login del backoffice: la API no pasa por las estrategias de Devise.
- **Límite de intentos por IP.** 10 intentos fallidos cada 3 minutos por IP. Después responde 429 con `Retry-After` y no evalúa la password, tampoco la correcta. Cuenta sólo los fallidos: `Admin::SessionsController` atrapa el `throw :warden` del fallo, lo cuenta y lo vuelve a tirar, así la respuesta sigue siendo la de Devise. Es el mismo criterio que TESIS-82 para el login de la API: por IP y no con `:lockable`.
  - ⚠️ No frena un ataque repartido entre muchas IPs. Se aceptó a cambio de no exponer al admin a un bloqueo provocado.
  - ⚠️ Las condiciones de despliegue son las de TESIS-82: el contador vive en la cache de la app (Solid Cache en producción), y `request.remote_ip` tiene que ser la IP del cliente y no la del proxy.
  - Cuando TESIS-82 llegue a `master` va a haber dos contadores parecidos (API en JSON, backoffice en HTML). Son candidatos a unificarse.

### Sesión

- **Vence a los 30 minutos sin actividad** (`:timeoutable`).
- **«Recordarme» se mantiene** y estira la sesión a las 2 semanas de `:rememberable`: Devise no aplica el timeout mientras esa cookie es válida. Se aceptó a propósito, y queda en manos del admin tildarlo sólo en una máquina de confianza.
- **El logout invalida la cookie, no sólo la borra del navegador.** El cookie store no guarda nada del lado del servidor, así que una cookie copiada antes del logout seguía abriendo el panel. Devise valida la cookie comparando `authenticatable_salt`. `AdminUser` le suma una columna `session_token`, y el logout la rota (`AdminUser#expire_sessions!`). El efecto es que el logout cierra **todas** las sesiones de esa cuenta, también la de «Recordarme» y la de otro navegador. Cambiar la password también las cierra, como antes.
- **`Cache-Control: no-store`** en todas las páginas de Avo (`Admin::UncacheablePages`). Con el default de Rails (`private, must-revalidate`), después del logout el botón «atrás» podía mostrar una página del panel desde la cache del navegador. El concern se incluye en `Avo::ApplicationController` desde el initializer, que es la forma que documenta Avo para sumar comportamiento a todos sus controllers sin copiar el suyo.
- **Orden de los middlewares.** Cookies, sesión y flash van antes de `Warden::Manager`. Con `config.middleware.use` quedaban después, porque Devise registra Warden al cargarse. Cuando Warden corta un request con `throw :warden`, el throw se salteaba el commit de la sesión. No tuvo consecuencias visibles hasta que se agregó el timeout: el cierre por inactividad no llegaba a la cookie y el navegador entraba en un loop de redirecciones.
- **Cookie:** `HttpOnly` y `SameSite=Lax`, los defaults de Rails. ⚠️ `Secure` depende de servir la app por HTTPS (`config.assume_ssl` / `config.force_ssl`), y eso corresponde a la card de seguridad transversal y despliegue.
- **CSRF:** Avo y el controller de sesiones de Devise usan `protect_from_forgery with: :exception`, así que un POST sin token responde 422. En test la protección está apagada; `spec/requests/admin/sessions_spec.rb` la prende para verificarlo.

### Datos sensibles: credenciales de las integraciones

Las credenciales de `company_integrations` son API keys y tokens de las cuentas de cada empresa. El backoffice las mostraba descifradas, en el detalle y en el formulario.

- El detalle muestra qué claves hay configuradas, con el valor enmascarado (`••••••`).
- El formulario no las edita. Las carga cada empresa por la API (`PUT /api/v1/integrations/:service_id`), que tampoco las devuelve nunca.
- Editarlas desde Avo, además, las rompía: el campo de código manda texto, y `serialize :credentials, coder: JSON` lo guardaba como String, con lo que `Integrations::HttpAdapter` fallaba al recorrerlas. Una fila que haya quedado así se muestra enmascarada entera.
- ⚠️ En Avo, `only_on: :show` saca un campo del formulario pero lo sigue aceptando en un PATCH armado a mano. Para que no se pueda escribir hace falta `disabled: true`. Vale para cualquier recurso nuevo.

### Datos cargados por las empresas

Los nombres y direcciones (de la empresa, de sus depósitos, del cliente de una orden, que puede llegar por webhook) se ven como texto: Avo escapa los valores en las listas, los detalles y los formularios. Queda verificado con HTML en esos campos en `spec/requests/admin/html_escaping_spec.rb`.

### Búsqueda en los listados

La búsqueda de empresas, usuarios y productos respondía 500: el lambda de `self.search` usaba `search_term`, y Avo 4 le pasa el texto buscado como `q`. Se corrigió en los tres recursos (`spec/requests/admin/resource_search_spec.rb`). Los resultados se muestran en el mismo listado, que ya escapa los valores.

### Alta de usuarios de empresa

El recurso User no pedía password, y crear un usuario desde el backoffice fallaba siempre.

- Al crear, el formulario pide password y confirmación. Al editar son opcionales (`devise_password_optional`) y sirven para asignar una nueva.
- La empresa es obligatoria y el email es único en toda la base: son las validaciones del modelo.
- Un usuario no se muda de empresa. El campo `company` no se envía al editar (`disabled` en la vista de edición), y si igual llegara un `company_id`, `CompanyScoped` rechaza el cambio.
- Las cuentas que crea el backoffice pueden loguearse en el acto.

## Alternativas consideradas

### `:lockable` para el límite de intentos

- ✅ Frena también un ataque desde muchas IPs contra la única cuenta de admin
- ❌ Cualquiera que sepa el email puede dejar al admin afuera
- ❌ Se aparta del criterio que TESIS-82 fijó para la API

### Sesiones del lado del servidor para que el logout las borre

Un store en la base (gema `activerecord-session_store`) o en la cache (`:cache_store`).

- ✅ El logout borraría esa sesión puntual, sin tocar las demás de la cuenta
- ❌ Una gema nueva, o sesiones en Solid Cache, que se desalojan con la cache
- ❌ En test la cache es `:null_store` y las sesiones no sobrevivirían entre requests
- ❌ El salt de Devise ya resuelve el problema con una columna

### Credenciales enmascaradas con un campo para reemplazarlas

- ✅ El admin podría cargar credenciales en nombre de una empresa
- ❌ Obliga a parsear y validar JSON en el backoffice para un caso de uso que no existe: las carga la empresa

### Sacar «Recordarme»

- ✅ El timeout valdría siempre
- ❌ Se prefirió dejar la comodidad a criterio del admin

## Consecuencias

- ✅ Una sesión robada deja de servir con el logout, y una olvidada vence sola a los 30 minutos
- ✅ Ni el mensaje ni el tiempo del login dicen qué emails de admin existen
- ✅ Las credenciales de las empresas no salen de la base en claro por ningún camino: ni la API ni el backoffice las muestran
- ✅ El alta de usuarios desde el backoffice funciona, y un usuario no se puede pasar a otra empresa
- ✅ La búsqueda de los listados funciona
- ⚠️ El logout cierra todas las sesiones de la cuenta, no sólo la del navegador que sale
- ⚠️ Con «Recordarme», la sesión dura 2 semanas aunque no haya actividad
- ⚠️ El límite por IP no frena un ataque distribuido
- ⚠️ La cookie no lleva `Secure` hasta que la app se sirva por HTTPS
