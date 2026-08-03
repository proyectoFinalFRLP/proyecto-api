# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Products API', type: :request do
  let(:company) { Company.create!(name: 'Tenant A', tax_id: '30-11111111-1') }
  let(:user) { User.create!(email: 'a@example.com', password: 'password123', company: company) }
  let(:headers) { auth_headers(user) }

  def auth_headers(user)
    post '/api/v1/auth/login', params: { email: user.email, password: 'password123' }
    { 'Authorization' => "Bearer #{response.parsed_body['token']}" }
  end

  def other_company
    @other_company ||= Company.create!(name: 'Tenant B', tax_id: '30-22222222-2')
  end

  def other_product
    @other_product ||= Product.create!(company: other_company, sku: 'B-001', name: 'Other')
  end

  def stocks_for(warehouse_id, quantity:)
    [{ warehouse_id: warehouse_id, quantity: quantity }]
  end

  describe 'GET /api/v1/products' do
    let(:warehouse) do
      Warehouse.create!(company: company, name: 'Central', zip_code: '1900', address: 'Calle 1')
    end

    it 'returns 401 without a token' do
      get '/api/v1/products'
      expect(response).to have_http_status(:unauthorized)
    end

    context 'when authenticated' do
      before do
        p1 = Product.create!(company: company, sku: 'A-001', name: 'Alpha')
        p2 = Product.create!(company: company, sku: 'A-002', name: 'Beta')
        Stock.create!(product: p1, warehouse: warehouse, quantity: 10)
        Stock.create!(product: p2, warehouse: warehouse, quantity: 5)
        Product.create!(company: other_company, sku: 'B-001', name: 'Other')

        get '/api/v1/products', headers: headers
      end

      it 'returns only the products of the current company', :aggregate_failures do
        body = response.parsed_body
        expect(body.length).to eq(2)
        expect(body.pluck('sku')).to match_array(%w[A-001 A-002])
      end

      it 'includes total_stock calculated via SQL aggregation', :aggregate_failures do
        body = response.parsed_body
        alpha = body.find { |p| p['sku'] == 'A-001' }
        beta  = body.find { |p| p['sku'] == 'A-002' }
        expect(alpha['total_stock']).to eq(10)
        expect(beta['total_stock']).to eq(5)
      end

      it 'includes product fields' do
        body = response.parsed_body
        expect(body.first.keys).to include('id', 'sku', 'name', 'total_stock')
      end

      it 'computes total_stock in a single aggregation query (no N+1)' do
        10.times do |i|
          p = Product.create!(company: company, sku: "N1-#{i}", name: "N1-#{i}")
          Stock.create!(product: p, warehouse: warehouse, quantity: i)
        end

        auth = headers
        queries = 0
        counter = lambda do |_name, _started, _finished, _id, payload|
          queries += 1 if payload[:sql].to_s.match?(/SUM.*stocks/i)
        end

        ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
          get '/api/v1/products', headers: auth
        end

        expect(response).to have_http_status(:ok)
        expect(queries).to eq(1)
      end
    end
  end

  describe 'GET /api/v1/products/:id' do
    let!(:product) do
      wh = Warehouse.create!(company: company, name: 'Central', zip_code: '1900', address: 'Calle 1')
      p = Product.create!(company: company, sku: 'A-001', name: 'Alpha')
      Stock.create!(product: p, warehouse: wh, quantity: 7)
      p
    end

    it 'returns 401 without a token' do
      get '/api/v1/products/1'
      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns the product with total_stock', :aggregate_failures do
      get "/api/v1/products/#{product.id}", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['total_stock']).to eq(7)
    end

    it 'returns 404 for a product from another company' do
      get "/api/v1/products/#{other_product.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it 'returns 403 when the policy denies access' do
      # Permite probar el rescue de Pundit::NotAuthorizedError: con CompanyScoped
      # el 404 por tenant suele ganarle al authorize, así que se fuerza la negación.
      allow_any_instance_of(ProductPolicy).to receive(:show?).and_return(false) # rubocop:disable RSpec/AnyInstance

      get "/api/v1/products/#{product.id}", headers: headers

      expect(response).to have_http_status(:forbidden)
    end

    it 'loads stock warehouses in a single query (no N+1)' do
      wh2 = Warehouse.create!(company: company, name: 'North', zip_code: '1901', address: 'Calle 2')
      wh3 = Warehouse.create!(company: company, name: 'South', zip_code: '1902', address: 'Calle 3')
      Stock.create!(product: product, warehouse: wh2, quantity: 2)
      Stock.create!(product: product, warehouse: wh3, quantity: 3)

      auth = headers
      warehouse_queries = 0
      counter = lambda do |_name, _started, _finished, _id, payload|
        warehouse_queries += 1 if payload[:sql].to_s.include?('FROM "warehouses"')
      end

      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
        get "/api/v1/products/#{product.id}", headers: auth
      end

      expect(response).to have_http_status(:ok)
      expect(warehouse_queries).to eq(1)
    end
  end

  describe 'POST /api/v1/products' do
    let(:warehouse) do
      Warehouse.create!(company: company, name: 'Central', zip_code: '1900', address: 'Calle 1')
    end
    let(:product_attrs) do
      { sku: 'PROD-001', name: 'Widget Alpha', description: 'A test product',
        weight: 0.5, dimensions: '10x15x20' }
    end

    it 'returns 401 without a token' do
      post '/api/v1/products', params: { product: product_attrs }, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it 'creates a product and returns 201', :aggregate_failures do
      expect do
        post '/api/v1/products', params: { product: product_attrs }, headers: headers, as: :json
      end.to change(Product, :count).by(1)

      expect(response).to have_http_status(:created)
    end

    it 'assigns the company from the JWT, ignoring any company_id in the body' do
      post '/api/v1/products',
           params: { product: product_attrs.merge(company_id: other_company.id) },
           headers: headers, as: :json
      expect(Product.last.company).to eq(company)
    end

    it 'creates nested stocks when provided' do
      params = { product: product_attrs.merge(stocks: stocks_for(warehouse.id, quantity: 15)) }
      expect { post '/api/v1/products', params: params, headers: headers, as: :json }
        .to change(Stock, :count).by(1)
    end

    it 'rejects a warehouse from another company' do
      other_wh = Warehouse.create!(company: other_company, name: 'Other',
                                   zip_code: '2000', address: 'Otra')
      params = { product: product_attrs.merge(stocks: stocks_for(other_wh.id, quantity: 5)) }
      post '/api/v1/products', params: params, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'returns 422 when stocks is an object instead of an array' do
      params = { product: product_attrs.merge(stocks: { warehouse_id: 1, quantity: 5 }) }

      expect do
        post '/api/v1/products', params: params, headers: headers, as: :json
      end.not_to change(Stock, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'does not create the product when stocks is malformed' do
      params = { product: product_attrs.merge(stocks: { warehouse_id: 1, quantity: 5 }) }

      expect do
        post '/api/v1/products', params: params, headers: headers, as: :json
      end.not_to change(Product, :count)
    end

    it 'returns 422 when a stock element is not an object' do
      params = { product: product_attrs.merge(stocks: ['string']) }

      expect do
        post '/api/v1/products', params: params, headers: headers, as: :json
      end.not_to change(Stock, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'returns 422 when SKU is duplicated' do
      Product.create!(company: company, sku: 'PROD-001', name: 'Existing')
      post '/api/v1/products', params: { product: product_attrs }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe 'PUT /api/v1/products/:id' do
    let!(:product) do
      Product.create!(company: company, sku: 'PROD-001', name: 'Original')
    end
    let(:warehouse) do
      Warehouse.create!(company: company, name: 'Central', zip_code: '1900', address: 'Calle 1')
    end

    it 'returns 401 without a token' do
      put "/api/v1/products/#{product.id}", params: { product: { name: 'Updated' } }, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it 'updates the product', :aggregate_failures do
      put "/api/v1/products/#{product.id}",
          params: { product: { name: 'Updated Name' } },
          headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(product.reload.name).to eq('Updated Name')
    end

    it 'returns 404 for a product from another company' do
      put "/api/v1/products/#{other_product.id}",
          params: { product: { name: 'Hack' } },
          headers: headers, as: :json
      expect(response).to have_http_status(:not_found)
    end

    it 'rejects stocks with a warehouse from another company' do
      other_wh = Warehouse.create!(company: other_company, name: 'Other',
                                   zip_code: '2000', address: 'Otra')
      params = { product: { stocks: stocks_for(other_wh.id, quantity: 5) } }
      put "/api/v1/products/#{product.id}", params: params, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'upserts nested stocks', :aggregate_failures do
      Stock.create!(product: product, warehouse: warehouse, quantity: 5)
      params = { product: { stocks: stocks_for(warehouse.id, quantity: 20) } }

      put "/api/v1/products/#{product.id}", params: params, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(product.stocks.find_by(warehouse: warehouse).quantity).to eq(20)
    end

    it 'returns 422 when stocks is an object instead of an array' do
      params = { product: { stocks: { warehouse_id: 1, quantity: 5 } } }

      put "/api/v1/products/#{product.id}", params: params, headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'returns 422 when a stock element is not an object' do
      params = { product: { stocks: ['string'] } }

      put "/api/v1/products/#{product.id}", params: params, headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe 'DELETE /api/v1/products/:id' do
    let!(:product) do
      Product.create!(company: company, sku: 'PROD-001', name: 'To Delete')
    end

    it 'returns 401 without a token' do
      delete "/api/v1/products/#{product.id}"
      expect(response).to have_http_status(:unauthorized)
    end

    it 'deletes the product and returns 204', :aggregate_failures do
      expect do
        delete "/api/v1/products/#{product.id}", headers: headers
      end.to change(Product, :count).by(-1)

      expect(response).to have_http_status(:no_content)
    end

    it 'returns 404 for a product from another company' do
      delete "/api/v1/products/#{other_product.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end
end
