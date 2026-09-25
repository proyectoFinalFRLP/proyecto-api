# frozen_string_literal: true

require 'rails_helper'

# Cotizar un alta antes de crear la orden (TESIS-131).
RSpec.describe 'Draft quotes API', type: :request do
  let(:company) { Company.create!(name: 'Tenant A', tax_id: '30-11111111-1') }
  let(:user) { User.create!(email: 'a@example.com', password: 'password123', company: company) }
  let(:headers) { auth_headers(user) }
  let(:rates) { 'https://fast.test/rates' }

  def warehouse
    @warehouse ||= Warehouse.create!(company: company, name: 'Central', zip_code: '1900',
                                     address: 'Calle 1')
  end

  def product
    @product ||= Product.create!(company: company, sku: 'S-1', name: 'Sensor', weight: 1.5)
  end

  def auth_headers(user)
    post '/api/v1/auth/login', params: { email: user.email, password: 'password123' },
                               headers: { 'X-Tenant-Slug' => user.company.slug }
    { 'Authorization' => "Bearer #{response.parsed_body['token']}" }
  end

  # Un courier con sus dos plantillas vinculadas: la que cotiza y la que despacha.
  def courier
    quote = Service.create!(service_name: 'Fast - Cotización', type: 'courier',
                            http_method: 'POST', uri: rates,
                            request_mapper: { 'cp' => 'destination_zip_code',
                                              'kilos' => 'total_weight' },
                            response_mapper: { 'precio' => 'shipping_cost',
                                               'dias' => 'estimated_days' })
    dispatch = Service.create!(service_name: 'Fast', type: 'courier', http_method: 'POST',
                               uri: 'https://fast.test/ordenes', quote_service: quote,
                               response_mapper: { 'numero' => 'tracking_number' })
    [quote, dispatch].map do |service|
      CompanyIntegration.create!(company: company, service: service,
                                 credentials: { 'access_token' => 'T' }, is_active: true)
    end
  end

  def draft(**overrides)
    { origin_warehouse_id: warehouse.id, destination_zip_code: '5000',
      destination_address: 'Av. Siempreviva 742',
      items: [{ product_id: product.id, quantity: 2 }] }.merge(overrides)
  end

  def quote_draft(body = draft, auth: headers)
    post '/api/v1/quotes', params: { quote: body }, headers: auth, as: :json
  end

  it 'returns 401 without a token' do
    post '/api/v1/quotes', params: { quote: draft }, as: :json

    expect(response).to have_http_status(:unauthorized)
  end

  context 'with a courier that answers' do
    before do
      courier
      stub_request(:post, rates).to_return(status: 200, body: { precio: 2500.0, dias: 3 }.to_json)
    end

    it 'returns the options in the same shape as the quote of an order', :aggregate_failures do
      quote_draft

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['data'].first.keys)
        .to match_array(%w[company_integration_id dispatch_integration_id provider_name
                           shipping_cost estimated_days])
    end

    it 'quotes the parcel of the draft: its weight and its destination' do
      quote_draft

      expect(WebMock).to have_requested(:post, rates)
        .with(body: hash_including('cp' => '5000', 'kilos' => '3.0'))
    end

    # El punto de la card: cotizar no crea la orden ni toca el stock.
    it 'does not create an order' do
      expect { quote_draft }.not_to change(Order, :count)
    end
  end

  it 'returns 200 with an empty list when no courier answers' do
    quote_draft

    expect(response.parsed_body).to eq('data' => [])
  end

  describe 'isolation between companies' do
    let(:other) { Company.create!(name: 'Tenant B', tax_id: '30-22222222-2') }

    it 'answers 404 for a warehouse of another company' do
      foreign = Warehouse.create!(company: other, name: 'Ajeno', zip_code: '1', address: 'x')
      quote_draft(draft(origin_warehouse_id: foreign.id))

      expect(response).to have_http_status(:not_found)
    end

    it 'answers 404 for a product of another company' do
      foreign = Product.create!(company: other, sku: 'X-1', name: 'Ajeno')
      quote_draft(draft(items: [{ product_id: foreign.id, quantity: 1 }]))

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'a malformed draft' do
    {
      'without the origin warehouse' => { origin_warehouse_id: nil },
      'without the destination zip code' => { destination_zip_code: '' },
      'without items' => { items: [] },
      'with a quantity of zero' => { items: [{ product_id: 1, quantity: 0 }] },
      'with a quantity that is not a number' => { items: [{ product_id: 1, quantity: 'dos' }] },
      'with an item that is not an object' => { items: ['S-1'] }
    }.each do |label, overrides|
      it "returns 400 #{label}" do
        quote_draft(draft(**overrides))

        expect(response).to have_http_status(:bad_request)
      end
    end

    it 'says which parameter is missing, like the rest of the API' do
      quote_draft(draft(destination_zip_code: ''))

      expect(response.parsed_body['error']).to include('destination_zip_code')
    end

    it 'returns 400 above the item limit of an order' do
      items = Array.new(Api::V1::OrdersController::MAX_ITEMS + 1) do
        { product_id: product.id, quantity: 1 }
      end
      quote_draft(draft(items: items))

      expect(response.parsed_body['error']).to include('maximum')
    end
  end
end
