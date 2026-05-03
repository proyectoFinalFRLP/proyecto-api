# Convenciones de código

## 1. RuboCop

El proyecto usa **RuboCop 1.86** con los plugins `rubocop-rails`, `rubocop-performance` y `rubocop-rspec`. La configuración está en `.rubocop.yml`.

```bash
bundle exec rubocop         # Verificar
bundle exec rubocop -A      # Auto-corregir
```

### Límites configurados

| Regla                 | Valor   |
| --------------------- | ------- |
| Longitud de línea     | 100 chars (excluye: routes, specs, Gemfile, seeds) |
| Longitud de método    | 20 líneas |
| Longitud de clase     | 150 líneas |
| Complejidad ABC       | 25      |

### Exclusiones

RuboCop no verifica: `db/migrate/*`, `db/schema.rb`, `config/initializers/*`, `config/environments/*`, `bin/*`, `db/seeds.rb`.

---

## 2. Ruby

### Strings

**Single quotes** para strings literales (enforced por RuboCop):

```ruby
# ✅ Correcto
name = 'John'
error_message = 'Email is invalid'

# ❌ Incorrecto
name = "John"
```

Usar **string interpolation** con double quotes solo cuando se interpola:

```ruby
# ✅ Correcto
message = "Hello, #{user.name}"
```

### Métodos

- `def` con paréntesis cuando hay parámetros, sin paréntesis cuando no hay:

```ruby
def perform         # Sin parámetros: sin paréntesis
def call(product)   # Con parámetros: con paréntesis
```

- **Guard clauses** para reducir anidamiento:

```ruby
# ✅ Correcto
def process
  return if stock.zero?
  return unless integration.active?
  # lógica principal
end

# ❌ Incorrecto
def process
  if stock > 0
    if integration.active?
      # lógica principal
    end
  end
end
```

### Hashes y símbolos

```ruby
# ✅ Ruby 3+ hash syntax
create_order(status: :pending, source: :manual)

# ✅ Cuando la clave no es símbolo
{ 'Content-Type' => 'application/json' }
```

### Condicionales de una línea (one-liners)

```ruby
# ✅ Para métodos de policy y casos simples
def show?    = record.company_id == user.company_id
def destroy? = false

# ✅ Para guards
return if user.nil?
raise NotFoundError unless product
```

---

## 3. Rails

### Controllers

Los controllers deben ser **finos**. Un controller action ideal:

```ruby
def create
  authorize Product
  product = Products::CreateProduct.new(
    params: product_params,
    company: current_company
  ).call
  render json: ProductSerializer.render(product), status: :created
end
```

Nunca poner lógica de negocio directamente en un action. Si el action tiene más de ~10 líneas de lógica, extraerla a un PORO.

### Models

- Validaciones declarativas con `validates`
- Scopes con nombres descriptivos: `scope :active, -> { where(status: :active) }`
- **No** poner lógica de negocio compleja en callbacks (`after_create`, etc.) — preferir POROs explícitos
- Relaciones siempre con nombre de la asociación en inglés, igual que la columna

### Queries

```ruby
# ✅ Correcto — scoped (multi-tenancy aplicado)
Order.where(status: :pending)
Order.find(params[:id])

# ✅ Para operaciones administrativas que requieren bypass
Order.unscoped.where(...)  # Solo en contextos explícitos (seeds, jobs administrativos)

# ❌ Nunca construir SQL manual con interpolación
Order.where("status = '#{params[:status]}'")  # SQL injection
Order.where(status: params[:status])  # ✅ Correcto
```

---

## 4. POROs

Cada PORO representa **un único caso de uso**. La interfaz pública es siempre `#call`:

```ruby
# app/poros/orders/confirm_order.rb
module Orders
  class ConfirmOrder < ApplicationPoro
    def initialize(order:, user:)
      @order = order
      @user = user
    end

    def call
      ActiveRecord::Base.transaction do
        @order.update!(status: :confirmed)
        reserve_stock
        StockUpdatedEvent.dispatch(@order)
      end
    end

    private

    def reserve_stock
      @order.order_items.each do |item|
        Catalog::DeductStock.new(product: item.product, quantity: item.quantity).call
      end
    end
  end
end
```

---

## 5. Serializers (Blueprinter)

```ruby
class OrderSerializer < ApplicationSerializer
  identifier :id
  fields :status, :source, :created_at

  # Para colecciones anidadas:
  association :order_items, blueprint: OrderItemSerializer

  # Para vistas diferenciadas:
  view :summary do
    fields :status, :created_at
  end
end

# Uso:
OrderSerializer.render(@order)                          # Vista default
OrderSerializer.render(@order, view: :summary)          # Vista summary
OrderSerializer.render(@orders)                         # Colección
```

---

## 6. Specs (RSpec)

### Estructura

```
spec/
├── models/[entidad]_spec.rb
├── requests/api/v1/[recurso]_spec.rb   # Specs de integración (HTTP)
├── policies/[entidad]_policy_spec.rb
├── poros/[dominio]/[caso_de_uso]_spec.rb
└── factories/[entidad].rb
```

### Patrón para request specs

```ruby
# spec/requests/api/v1/products_spec.rb
RSpec.describe 'GET /api/v1/products', type: :request do
  let(:company) { create(:company) }
  let(:user)    { create(:user, company: company) }
  let(:token)   { generate_jwt(user) }

  before { create_list(:product, 3, company: company) }

  it 'returns products for the authenticated company' do
    get '/api/v1/products', headers: { 'Authorization' => "Bearer #{token}" }

    expect(response).to have_http_status(:ok)
    expect(json_body.size).to eq(3)
  end

  it 'does not return products from other companies' do
    create(:product, company: create(:company))
    get '/api/v1/products', headers: { 'Authorization' => "Bearer #{token}" }

    expect(json_body.size).to eq(3)  # Solo los de la company del usuario
  end
end
```

### Patrón para policy specs

```ruby
# spec/policies/order_policy_spec.rb
RSpec.describe OrderPolicy do
  subject(:policy) { described_class.new(user, order) }

  let(:company) { create(:company) }
  let(:user)    { create(:user, company: company) }
  let(:order)   { create(:order, company: company) }

  it { is_expected.to permit_action(:show) }
  it { is_expected.to permit_action(:update) }

  context 'when the order belongs to another company' do
    let(:order) { create(:order, company: create(:company)) }

    it { is_expected.not_to permit_action(:show) }
  end
end
```

---

## 7. Naming conventions

| Elemento              | Formato       | Ejemplo                              |
| --------------------- | ------------- | ------------------------------------ |
| Clases y módulos      | `PascalCase`  | `OrdersController`, `ConfirmOrder`   |
| Métodos y variables   | `snake_case`  | `confirm_order`, `current_company`   |
| Constantes            | `UPPER_SNAKE` | `MAX_RETRY_COUNT = 5`                |
| Archivos              | `snake_case`  | `confirm_order.rb`                   |
| Tablas DB             | `snake_case`  | `order_items`, `company_integrations`|
| Columnas DB           | `snake_case`  | `company_id`, `external_order_id`    |
| Rutas API             | `kebab-case`  | `/api/v1/order-items`                |
