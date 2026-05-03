# Guía de Testing

Esta guía define los patrones, convenciones y estructura para escribir specs en el proyecto.

## 1. Filosofía

- **Request specs son los más importantes**: verifican el comportamiento completo del sistema incluyendo autenticación, multi-tenancy y formato JSON.
- **Cada spec tiene una sola responsabilidad**: un model spec verifica validaciones; un policy spec verifica autorización; un PORO spec verifica lógica de negocio.
- **Los specs espejean la estructura de `app/`**: si existe `app/poros/orders/confirm_order.rb`, el spec es `spec/poros/orders/confirm_order_spec.rb`.
- **Factories sobre fixtures**: siempre usar FactoryBot para crear datos de test.

## 2. Estructura de directorios

```
spec/
├── factories/
│   ├── companies.rb
│   ├── users.rb
│   ├── products.rb
│   └── orders.rb
├── models/
│   ├── product_spec.rb
│   └── order_spec.rb
├── policies/
│   ├── product_policy_spec.rb
│   └── order_policy_spec.rb
├── poros/
│   ├── catalog/
│   │   └── create_product_spec.rb
│   └── orders/
│       └── confirm_order_spec.rb
├── requests/
│   └── api/
│       └── v1/
│           ├── products_spec.rb
│           └── orders_spec.rb
├── jobs/
│   └── catalog/
│       └── sync_stock_to_channel_job_spec.rb
└── support/
    ├── shared_contexts/
    │   └── authenticated_user.rb
    └── helpers/
        └── jwt_helper.rb
```

## 3. Factories

Una factory por modelo. Incluir siempre `company` como asociación raíz del tenant.

```ruby
# spec/factories/companies.rb
FactoryBot.define do
  factory :company do
    sequence(:name) { |n| "Company #{n}" }
  end
end

# spec/factories/users.rb
FactoryBot.define do
  factory :user do
    company
    sequence(:email) { |n| "user#{n}@example.com" }
    password { 'password123' }
  end
end

# spec/factories/products.rb
FactoryBot.define do
  factory :product do
    company
    sequence(:sku) { |n| "SKU-#{n}" }
    name { 'Test Product' }
    stock { 10 }
  end
end
```

## 4. Shared Contexts y Helpers

Usar shared contexts para no repetir el setup de autenticación en cada spec.

```ruby
# spec/support/shared_contexts/authenticated_user.rb
RSpec.shared_context 'authenticated user' do
  let(:company) { create(:company) }
  let(:user)    { create(:user, company: company) }
  let(:headers) { jwt_headers_for(user) }
end
```

```ruby
# spec/support/helpers/jwt_helper.rb
module JwtHelper
  def jwt_headers_for(user)
    post '/api/v1/users/sign_in',
         params: { user: { email: user.email, password: 'password123' } }
    token = response.headers['Authorization']
    { 'Authorization' => token, 'Content-Type' => 'application/json' }
  end
end

RSpec.configure do |config|
  config.include JwtHelper, type: :request
end
```

## 5. Model Specs

Verificar validaciones, relaciones y scopes. No testear lógica de negocio aquí.

```ruby
# spec/models/product_spec.rb
RSpec.describe Product, type: :model do
  describe 'validations' do
    it { is_expected.to validate_presence_of(:sku) }
    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_numericality_of(:stock).is_greater_than_or_equal_to(0) }
    it { is_expected.to validate_uniqueness_of(:sku).scoped_to(:company_id) }
  end

  describe 'associations' do
    it { is_expected.to belong_to(:company) }
  end
end
```

## 6. Policy Specs

Verificar qué usuarios pueden hacer qué. Siempre testear el caso cross-tenant.

```ruby
# spec/policies/product_policy_spec.rb
RSpec.describe ProductPolicy, type: :policy do
  subject { described_class.new(user, product) }

  let(:company) { create(:company) }
  let(:user)    { create(:user, company: company) }
  let(:product) { create(:product, company: company) }

  context 'when user belongs to the same company' do
    it { is_expected.to permit_action(:show) }
    it { is_expected.to permit_action(:update) }
    it { is_expected.to permit_action(:destroy) }
  end

  context 'when product belongs to another company' do
    let(:other_company) { create(:company) }
    let(:product)       { create(:product, company: other_company) }

    it { is_expected.not_to permit_action(:show) }
    it { is_expected.not_to permit_action(:update) }
    it { is_expected.not_to permit_action(:destroy) }
  end
end
```

## 7. PORO Specs

Testear la lógica de negocio en aislamiento. Mockear solo dependencias externas (HTTP, jobs).

```ruby
# spec/poros/orders/confirm_order_spec.rb
RSpec.describe Orders::ConfirmOrder, type: :poro do
  describe '#call' do
    let(:company) { create(:company) }
    let(:product) { create(:product, company: company, stock: 5) }
    let(:order)   { create(:order, company: company, status: 'pending') }
    let!(:item)   { create(:order_item, order: order, product: product, quantity: 2) }

    subject { described_class.new(order: order).call }

    it 'confirms the order' do
      expect { subject }.to change { order.reload.status }.to('confirmed')
    end

    it 'decrements stock' do
      expect { subject }.to change { product.reload.stock }.from(5).to(3)
    end

    context 'when stock is insufficient' do
      let!(:item) { create(:order_item, order: order, product: product, quantity: 10) }

      it 'raises an error and does not confirm the order' do
        expect { subject }.to raise_error(Orders::InsufficientStockError)
        expect(order.reload.status).to eq('pending')
      end
    end
  end
end
```

## 8. Request Specs

Los más importantes. Cada endpoint debe verificar: autenticación, aislamiento multi-tenant, código HTTP y estructura JSON.

**Regla obligatoria:** todo endpoint de recurso individual (`show`, `update`, `destroy`) debe tener un test que verifique que un recurso de otro tenant devuelve **404** — no los datos, no 403.

```ruby
# spec/requests/api/v1/products_spec.rb
RSpec.describe 'Products API', type: :request do
  include_context 'authenticated user'

  describe 'GET /api/v1/products' do
    let!(:own_products)   { create_list(:product, 3, company: company) }
    let!(:other_products) { create_list(:product, 2, company: create(:company)) }

    it 'returns only products of the authenticated company' do
      get '/api/v1/products', headers: headers

      expect(response).to have_http_status(:ok)
      expect(response_ids).to match_array(own_products.map(&:id))
      expect(response_ids).not_to include(*other_products.map(&:id))
    end

    context 'without authentication' do
      it 'returns 401' do
        get '/api/v1/products'
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  describe 'GET /api/v1/products/:id' do
    context 'when product belongs to the company' do
      let(:product) { create(:product, company: company) }

      it 'returns the product' do
        get "/api/v1/products/#{product.id}", headers: headers
        expect(response).to have_http_status(:ok)
      end
    end

    context 'when product belongs to another company (cross-tenant)' do
      let(:product) { create(:product, company: create(:company)) }

      it 'returns 404 — does not reveal the resource exists' do
        get "/api/v1/products/#{product.id}", headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe 'POST /api/v1/products' do
    let(:valid_params) { { product: { sku: 'NEW-001', name: 'New Product', stock: 5 } } }

    it 'creates a product for the authenticated company' do
      expect {
        post '/api/v1/products', params: valid_params, headers: headers
      }.to change(Product, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(Product.last.company).to eq(company)
    end

    context 'with invalid params' do
      it 'returns 422' do
        post '/api/v1/products',
             params: { product: { sku: '', name: '' } },
             headers: headers
        expect(response).to have_http_status(:unprocessable_entity)
      end
    end
  end

  private

  def response_ids
    JSON.parse(response.body).map { |item| item['id'] }
  end
end
```

## 9. Job Specs

Verificar que el job setea `Current.company_id` antes de ejecutar la lógica.

```ruby
# spec/jobs/catalog/sync_stock_to_channel_job_spec.rb
RSpec.describe Catalog::SyncStockToChannelJob, type: :job do
  let(:company) { create(:company) }
  let(:product) { create(:product, company: company) }

  it 'sets the tenant context before executing' do
    expect(Current).to receive(:company_id=).with(company.id).ordered
    described_class.perform_now(company_id: company.id, product_id: product.id)
  end

  it 'is enqueued in the correct queue' do
    expect {
      described_class.perform_later(company_id: company.id, product_id: product.id)
    }.to have_enqueued_job(described_class)
  end
end
```

## 10. Comandos

```bash
bundle exec rspec                                          # Suite completa
bundle exec rspec spec/models/                            # Solo models
bundle exec rspec spec/requests/api/v1/                   # Solo request specs
bundle exec rspec spec/policies/                          # Solo policies
bundle exec rspec spec/poros/                             # Solo POROs
bundle exec rspec spec/requests/api/v1/products_spec.rb   # Archivo específico
bundle exec rspec --format documentation                  # Output detallado (útil en CI local)
bundle exec rspec --tag ~slow                             # Excluir specs lentos
```
