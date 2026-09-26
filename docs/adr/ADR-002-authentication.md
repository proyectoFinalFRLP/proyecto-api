# ADR-002: Autenticación con Devise + JWT

**Fecha:** 2026-04-03  
**Estado:** Aceptado

---

## Contexto

La API necesita autenticar usuarios de múltiples empresas (tenants) sin estado de sesión en el servidor. El frontend React consume la API enviando credenciales y recibiendo un token que se incluye en cada request subsiguiente. El token debe contener información del tenant (`company_id`) para inicializar el contexto multi-tenant.

## Decisión

Se adopta **Devise 5 + devise-jwt 0.13** para la autenticación.

- **Devise** gestiona el modelo `User`, el registro, login, recuperación de contraseñas y validaciones de credenciales.
- **devise-jwt** emite y verifica tokens JWT. El payload incluye `company_id` y `user_id`.
- El token se envía en el header `Authorization: Bearer <token>`.
- El `ApplicationController` autentica cada request con `before_action :authenticate_user!` (helper de Devise) y extrae el tenant del payload JWT.

## Alternativas consideradas

### JWT custom (sin Devise)

- ✅ Máximo control sobre el flujo de autenticación
- ❌ Requiere implementar manualmente registro, login, recuperación de contraseña, validaciones de email, etc.
- ❌ Mayor superficie de error en lógica de seguridad crítica

### Rodauth

- ✅ Framework de autenticación más moderno y modular que Devise
- ❌ Menor adopción en proyectos Rails existentes
- ❌ Curva de aprendizaje más pronunciada para el equipo
- ❌ Menos integración directa con el ecosistema Rails/RSpec

### OAuth 2.0 / SSO externo

- ✅ Delegación de autenticación a proveedores confiables (Google, GitHub)
- ❌ Complejidad excesiva para un proyecto académico con usuarios propios
- ❌ Requiere configuración externa (aplicaciones OAuth en cada proveedor)

## Consecuencias

- ✅ Devise provee registro, login, recuperación de contraseñas y validaciones probadas y seguras
- ✅ devise-jwt integra JWT con Devise sin reimplementar el flujo de autenticación
- ✅ El payload del JWT permite inicializar `Current.company_id` sin una query adicional a la DB
- ✅ Autenticación stateless: la API es horizontalmente escalable sin sesiones compartidas
- ✅ La revocación de tokens está implementada con una denylist en la DB (ver la actualización al pie)
- ⚠️ El secreto JWT debe rotarse periódicamente y mantenerse fuera del código fuente


---

## Actualización — revocación de tokens (2026-08-30, TESIS-106)

La consecuencia que decía que la revocación *requería* una denylist quedaba
anotada pero sin implementar: `User` usaba
`Devise::JWT::RevocationStrategies::Null`, que no revoca nada. En la práctica
**cerrar sesión sólo borraba el store del navegador y el token seguía siendo
válido contra la API hasta vencer**, hasta un día entero.

### Decisión

Se adopta `Devise::JWT::RevocationStrategies::Denylist` sobre la tabla
`jwt_denylist` (`jti` único, `exp` indexado), y se expone
`DELETE /api/v1/auth/logout`, que revoca el token con el que llega el request y
devuelve 204.

### Por qué se revoca por token y no por usuario

El `jti` identifica al **token**, no al usuario, y un mismo usuario puede tener
varios tokens vivos —dos navegadores, dos dispositivos—. Revocar por usuario los
cerraría todos, que no es lo que alguien pide cuando aprieta "cerrar sesión" en
una pestaña. Hay un spec dedicado a ese caso.

### Consecuencias

- ✅ Un token revocado deja de autenticar de inmediato, en cualquier endpoint
- ✅ El logout es idempotente desde el punto de vista del cliente: un reintento
  llega con el token ya revocado y recibe 401, sin romper por el `jti` repetido
- ⚠️ Cada request autenticado suma una consulta a `jwt_denylist`. Es una
  búsqueda por índice único sobre una tabla que se mantiene chica gracias a la
  limpieza diaria (`Auth::PurgeExpiredTokensJob`), pero deja de ser autenticación
  puramente stateless: es el precio de poder revocar
- ⚠️ La tabla es global y **no** lleva `CompanyScoped`. Filtrar por empresa
  dejaría pasar un token revocado desde otro contexto de tenant


---

## Actualización — QA del módulo de auth (2026-09-24, TESIS-82)

La validación del módulo encontró cuatro huecos en cómo se entra y cómo se
sigue adentro. Esta sección registra cómo se cerró cada uno.

### El registro es una solicitud de acceso

`POST /auth/register` creaba una cuenta que podía loguearse en el acto, dentro
de la empresa que nombrara el header `X-Tenant-Slug`. El slug es público (es el
subdominio), así que cualquiera podía darse de alta en cualquier empresa y leer
todos sus datos. TESIS-120 ya había sacado `company_id` del body, pero el slug
que lo reemplazó también lo elige quien llama.

Registrarse pasa a ser pedir acceso, que es lo que dice la pantalla S02
(«Solicitá acceso al espacio de operación de tu organización»):

- `users.approved`, booleano con **default `true`**. Las cuentas que ya existían
  y las que crean el backoffice, los seeds o la consola nacen habilitadas; sólo
  `Auth::RegisterUser` crea cuentas en `false`.
- Una cuenta sin aprobar no obtiene token: el login le responde el mismo 401 que
  a una password incorrecta. Se aprueba desde el backoffice (campo `approved` del
  recurso User).
- El endpoint responde **202 con el mismo cuerpo** haya creado la solicitud o no.
  El email es único en toda la base, y el viejo 422 «Email has already been
  taken» decía qué emails tenían cuenta en cualquier empresa. Los errores de
  formato se siguen informando, pero antes de mirar si el email existe: si no,
  una password corta respondería distinto según el email estuviera tomado.

Se descartó hacer el email único por empresa: resolvía la enumeración pero
pedía reemplazar la validación de Devise y una migración de índices, y el 202
indistinguible ya la cierra.

### La sesión se revisa en cada request, no sólo al loguearse

El JWT sigue siendo válido hasta vencer aunque cambie algo que el token no
puede saber. Una empresa dada de baja seguía operando hasta 24 h con los tokens
que ya tenía. `ApplicationController#authenticate_user!` revisa ahora, después
de Devise, que la empresa siga activa y la cuenta aprobada, y responde 401 si
no.

Va sobre `authenticate_user!` y no en `active_for_authentication?` a propósito:
el hook de Devise corta con 401 cualquier request que traiga el token, también
los que no exigen sesión (login, registro, tenant-config).

El logout es la excepción: `DELETE /auth/logout` sólo exige un token válido, y
revoca aunque la empresa esté inactiva o la cuenta sin aprobar. Si respondiera
401, el token nunca entraría a la denylist y, como el corte es reversible,
cualquier copia de él volvería a servir al reactivarse la empresa o aprobarse
de nuevo la cuenta dentro de sus 24 h.

El corte es una suspensión, no una baja: reactivar la empresa devuelve el
acceso a los tokens que siguen vivos y que nadie cerró. Revocar todos los tokens
de la empresa al desactivarla se descartó por ahora: la denylist guarda `jti`
emitidos, no sesiones abiertas, y no hay de dónde sacar los que no se cerraron.

### Límite de intentos por IP

No había freno: después de 30 passwords incorrectas seguidas, la correcta
entraba. Login y registro aceptan ahora 10 intentos cada 3 minutos por IP
(`Api::V1::Auth::AttemptLimit`) y después responden 429 con `Retry-After`.
Desde TESIS-129 el contador vive en `FailedAttemptLimit`, que el login de la
API comparte con el del backoffice (ver ADR-017), cada uno con su cuenta.

- En el login cuentan **sólo los intentos fallidos**. Contar todos (el
  `rate_limit` de Rails cuenta requests) dejaba afuera al undécimo operario que
  entra al turno detrás del mismo NAT, con la password correcta. Agotados los
  intentos se rechaza sin evaluar la password, también la correcta.
- En el registro cuentan todos, con el `rate_limit` de Rails: cada pedido crea
  una solicitud y no hay un uso normal que lo repita.

- Se prefirió al `:lockable` de Devise porque bloquear la cuenta deja que
  cualquiera deje afuera a otro usuario tipeando mal su password a propósito.
- El contador vive en la cache de la app: Solid Cache en producción, compartida
  por todos los procesos. ⚠️ El entorno desplegado necesita la base de cache
  (`proyecto_api_production_cache`), y `request.remote_ip` tiene que ser la IP
  del cliente y no la del proxy: si no, todos comparten un solo contador.

### El email del login se normaliza

Devise guarda el email en minúsculas y sin espacios, pero sólo normaliza al
guardar y en sus propios finders. `Auth::AuthenticateUser` busca con su propio
`find_by`, así que quien se registró como «Ana@Norte.com» recibía 401 con la
password correcta. Ahora normaliza igual antes de buscar.

### El tiempo del 401 no delata qué emails existen

Con un email inexistente (o un tenant no resuelto) no había password contra la
cual correr bcrypt, y el 401 volvía mucho antes que el de una password
incorrecta: el cuerpo era idéntico, pero el tiempo de respuesta enumeraba
usuarios. `Auth::AuthenticateUser` compara ahora contra un digest descartable,
armado con el mismo `Devise::Encryptor` y el mismo costo, cuando no encuentra la
cuenta.

- ⚠️ En `Auth::RegisterUser` queda una diferencia más chica: el camino del email
  ya tomado se saltea el INSERT. Se deja como limitación conocida.
