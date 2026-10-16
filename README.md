# OneStock: API

Backend del trabajo final de Ingeniería en Sistemas de Información (UTN FRLP). Es un **OMS (Order Management System) multi-tenant**: varias empresas gestionan, desde una sola plataforma, su catálogo, el stock por depósito, las ventas de todos sus canales y los envíos con operadores logísticos. Shopify funciona de punta a punta contra una tienda de prueba; Mercado Libre, Tiendanube, Andreani y Correo Argentino están cargados como plantillas de ejemplo.

- Una venta en un canal entra sola por webhook, descuenta stock y el stock nuevo se publica en los demás canales.
- Cada integración es una **plantilla de datos**, no código: sumar un proveedor es cargar su plantilla desde el backoffice.
- Ningún evento se pierde: lo que falla queda en una Dead Letter Queue, se reintenta solo y se puede reprocesar por API.
- Las empresas comparten la base y se aíslan por fila: una empresa nunca ve, ni puede adivinar, los datos de otra.

El front (React + TypeScript) está en [`proyecto-web`](https://github.com/proyectoFinalFRLP/proyecto-web).

---

## Levantarlo

Con Docker, sin instalar Ruby:

```bash
git clone https://github.com/proyectoFinalFRLP/proyecto-api.git && cd proyecto-api
docker network create onestock
docker run -d --name onestock-pg --network onestock -e POSTGRES_PASSWORD=admin postgres:16-alpine
docker run -d --name onestock-api --network onestock -p 3000:3000 -v "$(pwd):/rails" -w /rails -e PROYECTO_API_DATABASE_HOST=onestock-pg ruby:4.0.2-slim sleep infinity
docker exec onestock-api bash -c "apt-get update -qq && apt-get install -qq -y --no-install-recommends build-essential libpq-dev libyaml-dev pkg-config git && bundle install"
docker exec onestock-api bundle exec rails db:prepare
docker exec -it -e SOLID_QUEUE_IN_PUMA=1 onestock-api bundle exec rails server -b 0.0.0.0
```

La API queda en http://localhost:3000 y el backoffice en http://localhost:3000/admin. Para Windows, la instalación nativa, las cuentas de prueba y una demo de punta a punta de una venta por webhook, ver la **[guía de setup](docs/guides/setup-local.md)**.

Cuenta de prueba: `admin@norte.com` / `password123`, con el header `X-Tenant-Slug: norte`.

---

## Stack

Ruby 4.0.2 · Rails 8.1 (API-only) · PostgreSQL 16 · Solid Queue (la cola de jobs vive en PostgreSQL, sin Redis) · Devise + JWT · Pundit · Blueprinter · Avo (backoffice) · RSpec · RuboCop · Kamal.

## Arquitectura en una página

```
Request → ApplicationController (JWT + tenant) → Controller (Pundit) → PORO (caso de uso) → Model (CompanyScoped) → Serializer → JSON
Webhook → Gateway público (firma + log crudo, 202) → Solid Queue → Job (tenant) → PORO → DLQ si falla
```

- **Controllers finos, lógica en POROs**: un caso de uso por clase en `app/poros/<dominio>/`.
- **Multi-tenancy por fila**: el concern `CompanyScoped` filtra toda consulta por la empresa del JWT; un recurso de otra empresa responde 404.
- **Integraciones data-driven**: un único `HttpAdapter` ejecuta cualquier plantilla (`services`), con la autenticación, el formato y la traducción que ésta declara.
- **Concurrencia de stock**: advisory locks de PostgreSQL por producto.

## Documentación

| Documento | Para qué |
| --- | --- |
| [Guía de setup](docs/guides/setup-local.md) | Levantar el sistema desde cero y recorrerlo |
| [Flujo de un webhook](docs/guides/flujo-de-un-webhook.md) | Una venta, de Shopify al stock publicado, pieza por pieza |
| [Arquitectura](docs/guidelines/architecture.md) | Capas, multi-tenancy, colas, concurrencia |
| [Dominios](docs/guidelines/feature-structure.md) | Los seis dominios y sus dependencias |
| [ADRs](docs/adr/) | Las decisiones de arquitectura, con sus alternativas y consecuencias |
| [Convenciones](docs/guidelines/code-conventions.md), [testing](docs/guidelines/testing.md), [git](docs/guidelines/git-workflow.md) | Cómo se trabaja en el repo |

## Calidad

```bash
bundle exec rspec        # tests (con cobertura en coverage/)
bundle exec rubocop      # estilo
bundle exec brakeman -q  # seguridad
```

El CI corre los tres en cada pull request.
