# ADR-018: Seguridad transversal y configuración del despliegue

**Fecha:** 2026-09-29  
**Estado:** Aceptado

---

## Contexto

La demo corre en contenedores detrás de Caddy, que termina el TLS de los subdominios de DuckDNS: `api.` para la API (Thruster + Puma) y uno por empresa para el front (`norte.`, `sur.`, servidos por nginx). La infraestructura (Caddy, las variables de cada contenedor) vive en el servidor y no en el repo.

La QA de TESIS-130 revisó los controles que no son de un módulo en particular y encontró la API desplegable con defaults pensados para desarrollo:

- CORS respondía `Access-Control-Allow-Origin: *` a cualquier origen.
- `force_ssl` y `assume_ssl` estaban comentados: sin HSTS, y la cookie del backoffice salía sin `Secure` (ADR-017 lo dejó anotado para esta card).
- Sin `RAILS_ALLOWED_HOSTS`, Rails no validaba el Host.
- Sin `DEVISE_JWT_SECRET_KEY`, los JWT se firmaban con `secret_key_base`, que no es propio del entorno cuando sale de las credenciales del repo.
- El entrypoint del Dockerfile corre `db:prepare`, que siembra toda base nueva, y los seeds no distinguían entorno: el despliegue arrancaba con `admin@backoffice.com` / `admin123` y los usuarios de empresa con `password123`.

Del lado del front (proyecto-web, su ADR-008), nginx no mandaba ningún header de seguridad y `npm audit` reportaba 11 vulnerabilidades altas. El token de sesión vive en `localStorage`, así que un XSS equivale a robar la sesión.

## Decisión

### Variables obligatorias: sin ellas, la API no arranca

`config/environments/production.rb` corta el arranque si falta alguna de estas:

| Variable                | Qué define                                   | Ejemplo en la demo                          |
| ----------------------- | -------------------------------------------- | ------------------------------------------- |
| `DEVISE_JWT_SECRET_KEY` | Secreto con el que se firman los JWT         | `bin/rails secret`, uno distinto por entorno |
| `CORS_ALLOWED_ORIGINS`  | Orígenes del front, separados por comas      | `https://*.precision-logistics.duckdns.org` |
| `RAILS_ALLOWED_HOSTS`   | Hosts de la API, separados por comas         | `api.precision-logistics.duckdns.org`       |

Sin la primera, los tokens se firmarían con `secret_key_base`; sin la tercera, el Host no se validaría. Las dos dejan algo abierto sin que nada falle a la vista. Sin la segunda, CORS no dejaría pasar al front, que se rompería sin decir por qué. Un contenedor que no levanta se ve en el deploy; uno que levanta abierto no se ve nunca. La excepción es `SECRET_KEY_BASE_DUMMY`, que marca el `assets:precompile` del Dockerfile: arranca la app durante el build, cuando todavía no hay secretos del entorno.

### Secreto de los JWT

El fallback a `secret_key_base` queda sólo para desarrollo y test. Cada entorno firma con su propio secreto, así que un token emitido en otro entorno no pasa la verificación de la firma.

### CORS

Sólo el front puede llamar a la API desde un navegador. El riesgo de `*` no era que un sitio ajeno lea datos con el token del usuario, porque el token no viaja solo como una cookie. Era que cualquier página podía hacer requests a la API desde los navegadores de sus visitantes, por ejemplo repartir intentos de login entre muchas IPs y esquivar el límite por IP de TESIS-82.

- Como cada empresa entra por su subdominio, `CORS_ALLOWED_ORIGINS` acepta un comodín para ese único nivel: `https://*.dominio` vale para `norte.dominio`, pero no para `a.b.dominio` ni para el dominio sin subdominio. rack-cors compara los strings tal cual, así que el initializer lo traduce a una regex anclada.
- Sin la variable (desarrollo y test) se acepta `localhost` en cualquier puerto. En producción no hay fallback.
- El `ETag` sigue expuesto para el locking optimista de TESIS-101.
- `spec/requests/cors_spec.rb` fija el comportamiento sin la variable. El de producción depende del entorno y se verifica contra la imagen.

### HTTPS de punta a punta

- Caddy termina el TLS y redirige HTTP a HTTPS (308).
- Rails recibe HTTP plano del proxy. `assume_ssl` hace que lo tome como HTTPS y `force_ssl` suma `Strict-Transport-Security` y marca las cookies como `Secure`, entre ellas la de la sesión del backoffice.
- Rails no redirige nada: con `assume_ssl`, todo request cuenta como HTTPS. La redirección es la de Caddy.

### Hosts permitidos

Con `RAILS_ALLOWED_HOSTS` obligatoria, un request con otro Host (o con otro `X-Forwarded-Host`) recibe 403. `/up` queda afuera de la validación, porque el health check llega con el Host de quien lo hace (la IP del contenedor, `localhost`).

### Seeds

Las contraseñas del repo siguen siendo las de desarrollo y test. En producción, las de las cuentas sembradas salen de `SEED_USER_PASSWORD` (usuarios de empresa) y `SEED_ADMIN_PASSWORD` (administrador del backoffice). Sin ellas, o si alguna es una contraseña del repo, el seed no corre. Estas dos variables no las pide el arranque: sólo hacen falta cuando se siembra, que con el entrypoint es el primer arranque contra una base nueva.

`find_or_create_by!` no toca una cuenta que ya existe, y una base sembrada antes de este cambio tiene las contraseñas del repo. En producción el seed las rota: correr `bin/rails db:seed` con las variables cierra esas cuentas y deja como están las que ya tienen otra contraseña (`spec/db/seeds_spec.rb`).

### Front

Detalle en el ADR-008 de proyecto-web: CSP que limita los scripts al propio origen, `frame-ancestors`/`X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy` y HSTS en nginx; reglas de ESLint que prohíben insertar HTML sin escapar; `npm audit` en su CI.

Los datos que cargan las empresas o llegan por webhook se muestran como texto: React los escapa, y el backoffice ya estaba cubierto (ADR-017, `spec/requests/admin/html_escaping_spec.rb`).

## Alternativas consideradas

### Avisar en el log en vez de cortar el arranque

- ✅ Un deploy sin las variables seguiría funcionando
- ❌ Funcionaría abierto, y nadie lee el log de un contenedor que anda

### Una lista cerrada de orígenes, sin comodín

- ✅ Más explícita
- ❌ Cada empresa nueva obliga a cambiar la variable y reiniciar la API para que su front funcione

### `force_ssl` confiando en `X-Forwarded-Proto`, sin `assume_ssl`

- ✅ Rails redirigiría también un acceso directo por HTTP al contenedor
- ❌ Depende de que cada salto (Caddy → Thruster → Puma) reenvíe el header: si uno no lo hace, cada request vuelve redirigido a sí mismo

### Contraseñas al azar en los seeds, impresas en el log

- ✅ No hace falta ninguna variable
- ❌ Deja secretos en los logs, y el equipo no puede reproducir las cuentas de la demo

## Consecuencias

- ✅ Un token de otro entorno no sirve, y el deploy no arranca con un secreto que no sea propio
- ✅ Ninguna página que no sea el front puede llamar a la API desde un navegador
- ✅ La cookie del backoffice lleva `Secure` y el navegador recuerda que el sitio es HTTPS
- ✅ Ninguna cuenta sembrada en un entorno desplegado tiene una contraseña del repo
- ⚠️ El próximo deploy no arranca si el servidor no define las tres variables: hay que cargarlas antes
- ⚠️ Una base ya desplegada conserva las contraseñas del repo hasta que se corra `bin/rails db:seed` con `SEED_USER_PASSWORD` y `SEED_ADMIN_PASSWORD`
- ⚠️ `ENCRYPTION_KEY` y `ENCRYPTION_KEY_DERIVATION_SALT` siguen cayendo a `secret_key_base`. No entran en la validación del arranque: cambiarlas en una base que ya tiene credenciales cifradas las deja ilegibles, así que necesitan su propia migración
- ⚠️ Un acceso directo al contenedor por HTTP (sin Caddy) no se redirige: se asume que el puerto del contenedor no está expuesto
