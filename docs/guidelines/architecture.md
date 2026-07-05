# Arquitectura del proyecto

## 1. Descripción general

Backend del trabajo final de la carrera de Ingeniería en Sistemas de Información (FRLP). API REST en Ruby on Rails (API-only) que actúa como OMS (Order Management System) multi-tenant para la gestión de catálogo, stock, órdenes e integraciones con plataformas externas.

**Repositorio:** `proyectoFinalFRLP/proyecto-api`  
**Frontend:** `proyectoFinalFRLP/proyecto-web`  
**Gestor de tareas:** Jira (proyecto `TESIS`)

---

## 2. Stack tecnológico

| Tecnología      | Versión | Rol                                   |
| --------------- | ------- | ------------------------------------- |
| Ruby            | 4.0.2   | Lenguaje                              |
| Rails           | 8.1.2.1 | Framework (API-only)                  |
| PostgreSQL      | —       | Base de datos principal               |
| Puma            | 7.2.0   | Servidor web                          |
| Devise          | 5.0.3   | Autenticación                         |
| devise-jwt      | 0.13.0  | Tokens JWT                            |
| Pundit          | 2.5.2   | Autorización por políticas            |
| Blueprinter     | 1.2.1   | Serialización JSON                    |
| Solid Queue     | 1.4.0   | Background jobs (DB-backed)           |
| Solid Cache     | 1.0.10  | Caché (DB-backed)                     |
| Solid Cable     | 3.0.12  | Action Cable (DB-backed)              |
| RuboCop         | 1.86.0  | Linter (+ rails, performance, rspec)  |
| RSpec           | 8.0.4   | Testing                               |
| Lefthook        | 2.1.4   | Git hooks                             |
| Kamal           | 2.11.0  | Despliegue Docker                     |

### Variable de entorno

```bash
DEVISE_JWT_SECRET_KEY=<rails secret>   # Clave para firmar los tokens JWT
PROYECTO_API_DATABASE_PASSWORD=admin  # Contraseña de PostgreSQL (producción)
```

---

## 3. Estructura de carpetas

```
app/
├── controllers/
│   ├── application_controller.rb    # Base: authenticate_user!, set_current_tenant, error handling
│   ├── concerns/                    # Módulos reutilizables entre controllers
│   └── api/
│       └── v1/                      # Versión de la API
│           └── [recurso]_controller.rb
│
├── models/
│   ├── application_record.rb        # Base: Global Default Scope (multi-tenancy)
│   ├── current.rb                   # ActiveSupport::CurrentAttributes (company_id, user)
│   └── [entidad].rb
│
├── poros/                           # Plain Old Ruby Objects — lógica de negocio
│   ├── application_poro.rb          # Base class
│   └── [dominio]/
│       └── [caso_de_uso].rb         # Un PORO = un caso de uso
│
├── serializers/
│   ├── application_serializer.rb    # Base Blueprinter::Base
│   └── [entidad]_serializer.rb
│
├── policies/
│   ├── application_policy.rb        # Base Pundit::Policy
│   └── [entidad]_policy.rb
│
├── jobs/
│   ├── application_job.rb           # Base ApplicationJob (Solid Queue)
│   └── [dominio]/
│       └── [nombre]_job.rb
│
└── mailers/
    └── application_mailer.rb

config/
├── routes.rb                        # namespace :api > namespace :v1
├── database.yml                     # PostgreSQL (dev, test, prod + cache/queue DBs)
├── initializers/
│   ├── cors.rb                      # rack-cors: todos los orígenes (dev)
│   └── devise.rb                    # Configuración de Devise
└── environments/

db/
├── schema.rb                        # Schema autogenerado (no editar manualmente)
├── migrate/                         # Migraciones en orden cronológico
└── seeds.rb                         # Datos iniciales de desarrollo

spec/
├── rails_helper.rb
├── spec_helper.rb
├── models/
├── requests/api/v1/                 # Request specs (integration tests)
├── policies/
├── poros/
└── factories/                       # FactoryBot factories

.github/
├── workflows/
│   ├── ci.yml                       # Security + Lint + Test
│   ├── auto-assign-reviewer.yml
│   └── pr-title.yml
└── pull_request_template.md
```

---

## 4. Flujo de un request

```
Request (con Authorization: Bearer <jwt>)
  ↓
ApplicationController
  - before_action :authenticate_user!     (Devise JWT — verifica token)
  - before_action :set_current_tenant     (extrae company_id del JWT → Current.company_id)
  ↓
Controller específico (app/controllers/api/v1/)
  - before_action :set_[recurso]          (Model.find → aplica scope multi-tenant automáticamente)
  - authorize @recurso                    (Pundit — verifica que el usuario tiene permiso)
  - PORO.new(...).call                    (delega la lógica de negocio)
  ↓
PORO (app/poros/[dominio]/)
  - Orquesta Models, Jobs, otras clases
  ↓
Serializer (Blueprinter)
  - Formatea el objeto Ruby → JSON
  ↓
render json: ...
```

---

## 5. Multi-tenancy en detalle

### 5.1 Global Default Scope

```ruby
# app/models/application_record.rb
class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class
  default_scope { where(company_id: Current.company_id) if Current.company_id }
end
```

El scope se aplica automáticamente a toda query sobre modelos de dominio. `Order.all` es equivalente a `Order.where(company_id: Current.company_id)`.

### 5.2 Inicialización del contexto

```ruby
# app/controllers/application_controller.rb
before_action :set_current_tenant

def set_current_tenant
  Current.company_id = current_user&.company_id
end
```

### 5.3 Reglas para tablas

Toda tabla de dominio debe incluir:

```ruby
t.references :company, null: false, foreign_key: true
```

Las tablas de configuración del sistema (sin datos de tenant) como `services` (plantillas de APIs) no llevan `company_id`.

### 5.4 Workers y cronjobs

Los jobs deben inicializar el contexto manualmente:

```ruby
def perform(product_id, company_id)
  Current.company_id = company_id
  product = Product.find(product_id)  # El scope ya filtra por company_id
  # ...
end
```

---

## 6. Dominios de negocio

El proyecto está organizado en 6 dominios correspondientes a los epics de Jira:

| Dominio      | Epic       | Descripción                                              |
| ------------ | ---------- | -------------------------------------------------------- |
| `auth`       | TESIS-19   | Empresas, usuarios, depósitos, autenticación JWT         |
| `integrations` | TESIS-20 | Plantillas de APIs externas, credenciales por empresa    |
| `catalog`    | TESIS-21   | Productos, stock por depósito, sincronización multicanal |
| `webhooks`   | TESIS-22   | Gateway de webhooks, cola de mensajes, reintentos        |
| `orders`     | TESIS-23   | Órdenes de compra, ítems, consolidación multicanal       |
| `shipments`  | TESIS-24   | Envíos, cotización de couriers, tracking                 |

Los POROs y Jobs se organizan por dominio:

```
app/poros/
├── auth/
├── catalog/
├── orders/
└── shipments/

app/jobs/
├── catalog/
├── orders/
└── shipments/
```

---

## 7. Cómo agregar nuevas funcionalidades

### 7.1 Nuevo recurso

1. Crear migración con `company_id NOT NULL` + `FK`
2. Crear model en `app/models/`
3. Crear policy en `app/policies/`
4. Crear serializer en `app/serializers/`
5. Crear PORO(s) en `app/poros/[dominio]/` para los casos de uso
6. Crear controller en `app/controllers/api/v1/`
7. Registrar rutas en `config/routes.rb`
8. Crear specs en `spec/models/`, `spec/requests/`, `spec/policies/`, `spec/poros/`

### 7.2 Nuevo job de background

1. Crear en `app/jobs/[dominio]/[nombre]_job.rb`
2. El job recibe `company_id` como parámetro y setea `Current.company_id` al inicio
3. Encolar con `[Nombre]Job.perform_later(resource_id, Current.company_id)`

### 7.3 Nueva integración con plataforma externa

1. Insertar registro en la tabla `services` (plantilla de API) — sin código nuevo
2. La empresa configura sus credenciales vía el endpoint de `company_integrations`
3. El HTTP Adapter genérico usa la plantilla para construir el request

### 7.4 Nueva llamada HTTP a API externa

```ruby
# ✅ Siempre dentro de un PORO, nunca en controllers ni models
module Integrations
  class SyncProductToChannel < ApplicationPoro
    def initialize(product:, company_integration:)
      @product = product
      @integration = company_integration
    end

    def call
      HttpAdapter.new(@integration).call(
        endpoint: :update_stock,
        payload: { external_id: mapping.external_id, stock: @product.stock }
      )
    end
  end
end
```
