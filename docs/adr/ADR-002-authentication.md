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
- ⚠️ La revocación de tokens requiere una denylist en la DB (se configura en `devise-jwt`)
- ⚠️ El secreto JWT debe rotarse periódicamente y mantenerse fuera del código fuente
