# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Product Mappings API', type: :request do
  let(:company) { Company.create!(name: 'Tenant A', tax_id: '30-11111111-1') }
  let(:user) { User.create!(email: 'a@example.com', password: 'password123', company: company) }
  let(:headers) { auth_headers(user) }
  let(:product) { Product.create!(company: company, sku: 'A-001', name: 'Alpha') }

  def auth_headers(user)
    post '/api/v1/auth/login', params: { email: user.email, password: 'password123' }
    { 'Authorization' => "Bearer #{response.parsed_body['token']}" }
  end

  def mappings_url(product_id)
    "/api/v1/products/#{product_id}/mappings"
  end

  def create_service(name, uri)
    Service.create!(service_name: name, type: 'ecommerce', uri: uri, http_method: 'GET')
  end

  # Current.company_id puede quedar seteado del login previo y CompanyScoped
  # pisaría el company: manual, así que las integraciones se crean con el
  # contexto en nil para que nazcan SIEMPRE en la empresa indicada.
  def create_integration(owner, service)
    Current.set(company_id: nil) do
      CompanyIntegration.create!(company: owner, service: service, credentials: { token: 'x' })
    end
  end

  def meli_integration
    @meli_integration ||= create_integration(company, create_service('Mercado Libre', 'https://api.meli.com'))
  end

  def shopify_integration
    @shopify_integration ||= create_integration(company, create_service('Shopify', 'https://api.shopify.com'))
  end

  def other_company
    @other_company ||= Company.create!(name: 'Tenant B', tax_id: '30-22222222-2')
  end

  def other_product
    # Mismo motivo que create_integration: sin forzar Current a nil el producto
    # nacería en la empresa del usuario logueado y el test perdería sentido.
    @other_product ||= Current.set(company_id: nil) do
      Product.create!(company: other_company, sku: 'B-001', name: 'Other')
    end
  end

  def other_integration
    @other_integration ||= create_integration(other_company, create_service('Tiendanube', 'https://api.tn.com'))
  end

  def mapping_for(mapped_product, integration, external_id, price: nil)
    ProductMapping.create!(product: mapped_product, company_integration: integration,
                           external_product_id: external_id, external_price: price)
  end

  def link_external_id_to_another_product(external_id)
    sibling = Product.create!(company: company, sku: 'A-999', name: 'Sibling')
    mapping_for(sibling, meli_integration, external_id)
  end

  def count_queries(matching:, &block)
    count = 0
    counter = lambda do |_name, _started, _finished, _id, payload|
      count += 1 if payload[:sql].to_s.match?(matching)
    end

    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &block)

    count
  end

  describe 'GET /api/v1/products/:product_id/mappings' do
    it 'returns 401 without a token' do
      get mappings_url(product.id)
      expect(response).to have_http_status(:unauthorized)
    end

    # Misma envoltura que GET /api/v1/products (TESIS-33): el front no tiene que
    # tratar dos shapes distintas en endpoints vecinos del mismo árbol.
    it 'wraps the collection in a data key', :aggregate_failures do
      mapping_for(product, meli_integration, 'MLA-123')
      get mappings_url(product.id), headers: headers

      expect(response.parsed_body).to be_a(Hash)
      expect(response.parsed_body.keys).to eq(['data'])
      expect(response.parsed_body['data']).to be_an(Array)
    end

    it 'returns the mappings of the product', :aggregate_failures do
      mapping_for(product, meli_integration, 'MLA-123')
      get mappings_url(product.id), headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['data'].length).to eq(1)
      expect(response.parsed_body['data'].first['external_product_id']).to eq('MLA-123')
    end

    it 'includes the external service so the front can label the channel', :aggregate_failures do
      mapping_for(product, meli_integration, 'MLA-123')
      get mappings_url(product.id), headers: headers

      expect(response.parsed_body['data'].first['service_name']).to eq('Mercado Libre')
      expect(response.parsed_body['data'].first['service_id']).to eq(meli_integration.service_id)
    end

    it 'exposes external_price as a JSON number, not a string', :aggregate_failures do
      mapping_for(product, meli_integration, 'MLA-123', price: 1500.5)
      get mappings_url(product.id), headers: headers

      expect(response.parsed_body['data'].first['external_price']).to eq(1500.5)
      expect(response.parsed_body['data'].first['external_price']).to be_a(Numeric)
    end

    it 'does not return the mappings of other products' do
      mapping_for(product, meli_integration, 'MLA-123')
      mapping_for(Product.create!(company: company, sku: 'A-002', name: 'Beta'),
                  meli_integration, 'MLA-999')

      get mappings_url(product.id), headers: headers
      expect(response.parsed_body['data'].pluck('external_product_id')).to eq(['MLA-123'])
    end

    it 'returns 404 for a product from another company' do
      get mappings_url(other_product.id), headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it 'loads the external services in a single query (no N+1)', :aggregate_failures do
      mapping_for(product, meli_integration, 'MLA-123')
      mapping_for(product, shopify_integration, 'SHP-999')

      queries = count_queries(matching: /FROM "services"/) { get mappings_url(product.id), headers: headers }
      expect(response).to have_http_status(:ok)
      expect(queries).to eq(1)
    end
  end

  describe 'POST /api/v1/products/:product_id/mappings' do
    # El body va anidado bajo `product_mapping`, mismo contrato que
    # POST /api/v1/products, que espera todo bajo `product`.
    let(:valid_params) do
      { product_mapping: { company_integration_id: meli_integration.id,
                           external_product_id: 'MLA-123' } }
    end

    def post_mapping(product_id: product.id, **attrs)
      post mappings_url(product_id), params: { product_mapping: attrs }, headers: headers, as: :json
    end

    it 'returns 401 without a token' do
      post mappings_url(product.id), params: valid_params, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    # ParamsWrapper (activo por defecto en ActionController::API para JSON)
    # envuelve el body plano bajo la key del recurso, así que pedir el anidado
    # no rompe a quien mande plano: las dos formas terminan en el mismo lugar.
    # Antes era al revés — el anidado fallaba con "company_integration_id is
    # required", que apuntaba al parámetro equivocado.
    it 'also accepts the flat payload thanks to ParamsWrapper', :aggregate_failures do
      params = { company_integration_id: meli_integration.id, external_product_id: 'MLA-123' }

      expect { post mappings_url(product.id), params: params, headers: headers, as: :json }
        .to change(ProductMapping, :count).by(1)
      expect(response).to have_http_status(:created)
    end

    it 'creates the mapping and returns 201', :aggregate_failures do
      expect do
        post mappings_url(product.id), params: valid_params, headers: headers, as: :json
      end.to change(ProductMapping, :count).by(1)

      expect(response).to have_http_status(:created)
    end

    it 'returns the created mapping with its service name', :aggregate_failures do
      post mappings_url(product.id), params: valid_params, headers: headers, as: :json

      expect(response.parsed_body).to include('external_product_id' => 'MLA-123',
                                              'service_name' => 'Mercado Libre')
      expect(response.parsed_body['product_id']).to eq(product.id)
    end

    it 'stores the optional external_price', :aggregate_failures do
      post_mapping(company_integration_id: meli_integration.id,
                   external_product_id: 'MLA-123', external_price: 2999.99)

      expect(response).to have_http_status(:created)
      expect(ProductMapping.last.external_price).to eq(2999.99)
    end

    it 'returns 404 when the integration belongs to another company', :aggregate_failures do
      expect do
        post_mapping(company_integration_id: other_integration.id,
                     external_product_id: 'MLA-999')
      end.not_to change(ProductMapping, :count)
      expect(response).to have_http_status(:not_found)
    end

    it 'returns 404 for a product from another company' do
      post mappings_url(other_product.id), params: valid_params, headers: headers, as: :json
      expect(response).to have_http_status(:not_found)
    end

    it 'returns 409 when the external id is already linked in that integration', :aggregate_failures do
      link_external_id_to_another_product('MLA-123')

      expect { post mappings_url(product.id), params: valid_params, headers: headers, as: :json }
        .not_to change(ProductMapping, :count)
      expect(response).to have_http_status(:conflict)
    end

    it 'explains that the external id is already taken' do
      link_external_id_to_another_product('MLA-123')
      post mappings_url(product.id), params: valid_params, headers: headers, as: :json

      expect(response.parsed_body['error']).to include('already linked to another product')
    end

    it 'returns 422 when the product is already mapped to that integration', :aggregate_failures do
      mapping_for(product, meli_integration, 'MLA-000')

      expect { post mappings_url(product.id), params: valid_params, headers: headers, as: :json }
        .not_to change(ProductMapping, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'returns 422 when external_product_id is missing' do
      post_mapping(company_integration_id: meli_integration.id)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'returns 422 when company_integration_id is missing', :aggregate_failures do
      post_mapping(external_product_id: 'MLA-123')

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to include('company_integration_id')
    end

    # external_price es decimal(10,2): sin validación, cualquiera de estos tres
    # casos terminaba en un 500 (RangeError) o en un precio silenciosamente
    # equivocado guardado en la DB.
    describe 'external_price validation' do
      def post_price(price)
        post_mapping(company_integration_id: meli_integration.id,
                     external_product_id: 'MLA-123', external_price: price)
      end

      it 'accepts the largest price the column can hold', :aggregate_failures do
        post_price(99_999_999.99)

        expect(response).to have_http_status(:created)
        expect(ProductMapping.last.external_price).to eq(99_999_999.99)
      end

      it 'returns 422 instead of 500 when the price overflows the column', :aggregate_failures do
        expect { post_price(100_000_000) }.not_to change(ProductMapping, :count)
        expect(response).to have_http_status(:unprocessable_content)
      end

      it 'returns 422 when the price would round past the column limit', :aggregate_failures do
        expect { post_price(99_999_999.999) }.not_to change(ProductMapping, :count)
        expect(response).to have_http_status(:unprocessable_content)
      end

      it 'returns 422 instead of storing 0.0 for a non-numeric price', :aggregate_failures do
        expect { post_price('abc') }.not_to change(ProductMapping, :count)
        expect(response).to have_http_status(:unprocessable_content)
      end

      it 'returns 422 for a negative price', :aggregate_failures do
        expect { post_price(-50) }.not_to change(ProductMapping, :count)
        expect(response).to have_http_status(:unprocessable_content)
      end

      it 'still accepts a mapping without price', :aggregate_failures do
        post_price(nil)

        expect(response).to have_http_status(:created)
        expect(ProductMapping.last.external_price).to be_nil
      end
    end
  end

  describe 'DELETE /api/v1/products/:product_id/mappings/:id' do
    it 'returns 401 without a token' do
      mapping = mapping_for(product, meli_integration, 'MLA-123')
      delete "#{mappings_url(product.id)}/#{mapping.id}"
      expect(response).to have_http_status(:unauthorized)
    end

    it 'deletes the mapping and returns 204', :aggregate_failures do
      mapping = mapping_for(product, meli_integration, 'MLA-123')

      expect { delete "#{mappings_url(product.id)}/#{mapping.id}", headers: headers }
        .to change(ProductMapping, :count).by(-1)
      expect(response).to have_http_status(:no_content)
    end

    it 'returns 404 when the mapping belongs to another product', :aggregate_failures do
      sibling = Product.create!(company: company, sku: 'A-002', name: 'Beta')
      mapping = mapping_for(sibling, meli_integration, 'MLA-999')

      delete "#{mappings_url(product.id)}/#{mapping.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it 'returns 404 for a product from another company' do
      mapping = mapping_for(other_product, other_integration, 'MLA-123')
      delete "#{mappings_url(other_product.id)}/#{mapping.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end
end
