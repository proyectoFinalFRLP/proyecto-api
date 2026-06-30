# CLAUDE.md

## Antes de empezar cualquier tarea

Leer obligatoriamente estos archivos en este orden antes de escribir una sola línea de código:

1. [`docs/guidelines/architecture.md`](docs/guidelines/architecture.md) — estructura de carpetas, capas, multi-tenancy, patrones de implementación
2. [`docs/guidelines/code-conventions.md`](docs/guidelines/code-conventions.md) — RuboCop, naming, Ruby conventions, testing
3. [`docs/guidelines/feature-structure.md`](docs/guidelines/feature-structure.md) — los 6 dominios, reglas de dependencia, cómo agregar código nuevo
4. [`docs/guidelines/git-workflow.md`](docs/guidelines/git-workflow.md) — ramas, commits, PRs, hooks
5. El ADR del dominio relevante según la tarea (ver [`docs/adr/`](docs/adr/))

Si la tarea viene de una card de Jira, leer la card completa en https://proyectofinalfrlp.atlassian.net/browse/TESIS-XXX antes de planificar la implementación.

---

## Proyecto

Backend del trabajo final de la carrera de Ingeniería en Sistemas de Información (FRLP). API REST construida con Ruby on Rails en modo API-only que actúa como **OMS (Order Management System) multi-tenant**: permite a múltiples empresas gestionar catálogo, stock, órdenes de venta e integraciones con plataformas externas (Mercado Libre, Tiendanube, Shopify) y operadores logísticos desde una única plataforma.

**Repositorio:** `proyectoFinalFRLP/proyecto-api`  
**Frontend:** `proyectoFinalFRLP/proyecto-web` (React + TypeScript)  
**Gestor de tareas:** Jira (proyecto `TESIS`) — https://proyectofinalfrlp.atlassian.net/jira/software/projects/TESIS/list

---

## Comandos esenciales

```bash
bundle install              # Instalar dependencias

bin/setup                   # Setup completo (requiere PostgreSQL corriendo)

bin/rails server            # Servidor de desarrollo en localhost:3000

bundle exec rspec           # Suite completa de tests
bundle exec rspec spec/requests/api/v1/orders_spec.rb  # Archivo específico

bundle exec rubocop         # Verificar linting
bundle exec rubocop -A      # Auto-corregir

bundle exec brakeman -q     # Escaneo de seguridad
bundle exec bundle-audit check --update  # Gems con vulnerabilidades
```

### Variables de entorno

Copiar `.env.example` a `.env` y completar:

```bash
DEVISE_JWT_SECRET_KEY=   # Generar con: rails secret
PROYECTO_API_DATABASE_PASSWORD=admin
```

---

## Stack tecnológico

| Tecnología  | Versión | Rol                                   |
| ----------- | ------- | ------------------------------------- |
| Ruby        | 4.0.2   | Lenguaje                              |
| Rails       | 8.1.2.1 | Framework (API-only)                  |
| PostgreSQL  | —       | Base de datos principal               |
| Devise      | 5.0.3   | Autenticación de usuarios             |
| devise-jwt  | 0.13.0  | Tokens JWT para la API                |
| Pundit      | 2.5.2   | Autorización por políticas            |
| Blueprinter | 1.2.1   | Serialización JSON                    |
| Solid Queue | 1.4.0   | Cola de trabajos en background (DB)   |
| RuboCop     | 1.86.0  | Linter (+ rails, performance, rspec)  |
| RSpec       | 8.0.4   | Framework de testing                  |
| Lefthook    | 2.1.4   | Git hooks                             |
| Kamal       | 2.11.0  | Despliegue con Docker                 |

---

## Arquitectura

Ver documentación completa en [`docs/guidelines/architecture.md`](docs/guidelines/architecture.md).

### Flujo de un request

```
Request
  → ApplicationController (authenticate_user!, set_current_tenant)
    → Controller específico (autorizar con Pundit, delegar a PORO)
      → PORO (lógica de negocio)
        → Model (validaciones, relaciones, queries con scope multi-tenant)
      → Serializer (Blueprinter)
  → JSON Response
```

### Capas y responsabilidades

| Capa        | Ubicación                 | Responsabilidad                                        |
| ----------- | ------------------------- | ------------------------------------------------------ |
| Controllers | `app/controllers/api/v1/` | Routing, autenticación, autorización, serialización    |
| Models      | `app/models/`             | Validaciones, relaciones, scopes                       |
| POROs       | `app/poros/[dominio]/`    | Lógica de negocio compleja (un caso de uso por clase)  |
| Serializers | `app/serializers/`        | Formato JSON de respuesta (Blueprinter)                |
| Policies    | `app/policies/`           | Reglas de autorización por recurso (Pundit)            |
| Jobs        | `app/jobs/`               | Workers de background asíncronos (Solid Queue)         |

**Regla crítica:** los controllers son finos. Toda lógica que no sea routing/autenticación/autorización/serialización va en un PORO.

---

## Multi-tenancy

El sistema implementa **row-level multi-tenancy**: todas las empresas comparten la misma base de datos; el aislamiento se garantiza a nivel de fila mediante un scope automático de `company_id`.

**Cómo funciona:**

1. El JWT del usuario contiene `company_id` en su payload.
2. El `ApplicationController` extrae `company_id` del token y lo setea en `Current.company_id` (via `ActiveSupport::CurrentAttributes`).
3. El `ApplicationRecord` define un **Global Default Scope** que filtra automáticamente todas las queries: `where(company_id: Current.company_id)`.
4. Resultado: `Order.all` devuelve solo las órdenes de la empresa del usuario autenticado, sin código adicional en cada controller.

**Reglas:**
- Toda tabla de dominio debe tener `company_id NOT NULL` con FK a `companies`.
- Los workers de background deben setear `Current.company_id` manualmente al inicio de cada job.
- Un usuario que intenta acceder a un recurso de otro tenant recibe **404** (no 403), para no confirmar la existencia del recurso.

---

## Patrones de implementación

### Agregar un nuevo recurso completo (ejemplo: `Product`)

#### 1. Migración

```ruby
# db/migrate/YYYYMMDDHHMMSS_create_products.rb
class CreateProducts < ActiveRecord::Migration[8.1]
  def change
    create_table :products do |t|
      t.references :company, null: false, foreign_key: true
      t.string :sku, null: false
      t.string :name, null: false
      t.integer :stock, default: 0, null: false
      t.timestamps
    end
    add_index :products, %i[company_id sku], unique: true
  end
end
```

#### 2. Modelo

```ruby
# app/models/product.rb
class Product < ApplicationRecord
  belongs_to :company

  validates :sku, presence: true, uniqueness: { scope: :company_id }
  validates :name, presence: true
  validates :stock, numericality: { greater_than_or_equal_to: 0 }
end
```

#### 3. Policy (Pundit)

```ruby
# app/policies/product_policy.rb
class ProductPolicy < ApplicationPolicy
  def index?   = user.present?
  def show?    = record.company_id == user.company_id
  def create?  = user.present?
  def update?  = record.company_id == user.company_id
  def destroy? = record.company_id == user.company_id
end
```

#### 4. Serializer (Blueprinter)

```ruby
# app/serializers/product_serializer.rb
class ProductSerializer < ApplicationSerializer
  identifier :id
  fields :sku, :name, :stock, :created_at, :updated_at
end
```

#### 5. PORO (lógica de negocio)

```ruby
# app/poros/products/create_product.rb
module Products
  class CreateProduct < ApplicationPoro
    def initialize(params:, company:)
      @params = params
      @company = company
    end

    def call
      Product.create!(@params.merge(company: @company))
    end
  end
end
```

#### 6. Controller

```ruby
# app/controllers/api/v1/products_controller.rb
module Api
  module V1
    class ProductsController < ApplicationController
      before_action :authenticate_user!
      before_action :set_product, only: %i[show update destroy]

      def index
        products = policy_scope(Product)
        render json: ProductSerializer.render(products)
      end

      def show
        render json: ProductSerializer.render(@product)
      end

      def create
        authorize Product
        product = Products::CreateProduct.new(
          params: product_params,
          company: current_company
        ).call
        render json: ProductSerializer.render(product), status: :created
      end

      private

      def set_product
        @product = Product.find(params[:id])
        authorize @product
      end

      def product_params
        params.require(:product).permit(:sku, :name, :stock)
      end
    end
  end
end
```

#### 7. Ruta

```ruby
# config/routes.rb
namespace :api do
  namespace :v1 do
    resources :products, only: %i[index show create update destroy]
  end
end
```

---

## Trabajar con una card de Jira

1. Leer la card: `https://proyectofinalfrlp.atlassian.net/browse/TESIS-XXX`
2. Crear rama: `TESIS-XXX-descripcion-en-kebab-case`
3. Implementar siguiendo los patrones documentados aquí
4. Escribir specs en `spec/` correspondiente
5. `bundle exec rubocop` sin errores
6. `bundle exec rspec` en verde
7. PR con título: `tipo: [TESIS-XXX] descripción en inglés`

---

## Convenciones de código (resumen)

Ver detalle en [`docs/guidelines/code-conventions.md`](docs/guidelines/code-conventions.md).

- **Single quotes** para strings (enforced por RuboCop)
- **Longitud de línea:** máximo 100 caracteres
- **Longitud de método:** máximo 20 líneas
- **Longitud de clase:** máximo 150 líneas
- **Controllers finos:** toda lógica de negocio va en POROs
- **Commits en inglés**, formato Conventional Commits: `feat: add product model`

---

## Testing

- Framework: **RSpec**
- Los specs espejan la estructura de `app/`: `spec/models/`, `spec/requests/api/v1/`, `spec/policies/`, `spec/poros/`
- Factories en `spec/factories/`

```bash
bundle exec rspec spec/models/
bundle exec rspec spec/requests/api/v1/
bundle exec rspec spec/policies/
```

---

## CI/CD

Pipeline en `.github/workflows/ci.yml`, se ejecuta en push y PR a `master`/`develop`:

| Job        | Acción                                       |
| ---------- | -------------------------------------------- |
| `security` | Brakeman + Bundler-audit                     |
| `lint`     | RuboCop                                      |
| `test`     | RSpec con servicio PostgreSQL efímero        |

---

## Documentación completa

| Documento                                                      | Contenido                                           |
| -------------------------------------------------------------- | --------------------------------------------------- |
| [docs/guidelines/architecture.md](docs/guidelines/architecture.md) | Estructura de carpetas, capas, multi-tenancy, patrones |
| [docs/guidelines/code-conventions.md](docs/guidelines/code-conventions.md) | RuboCop, Ruby conventions, naming           |
| [docs/guidelines/feature-structure.md](docs/guidelines/feature-structure.md) | Dominios de negocio, cómo agregar features  |
| [docs/guidelines/git-workflow.md](docs/guidelines/git-workflow.md) | Ramas, commits, PRs, hooks, CI              |
| [docs/guidelines/pr-guidelines.md](docs/guidelines/pr-guidelines.md) | Cómo redactar PRs                           |
| [docs/adr/](docs/adr/)                                         | Decisiones arquitectónicas (ADRs)                   |
