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
