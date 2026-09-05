# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Shipment quotes API', type: :request do
  let(:company) { Company.create!(name: 'Tenant A', tax_id: '30-11111111-1') }
  let(:user) { User.create!(email: 'a@example.com', password: 'password123', company: company) }
  let(:headers) { auth_headers(user) }
  let(:warehouse) do
    Warehouse.create!(company: company, name: 'Central', zip_code: '1900', address: 'Calle 1')
  end
  let(:order) do
    Order.create!(company: company, customer_name: 'Ana', customer_zip_code: '5000',
                  customer_address: 'Av. Siempreviva 742')
  end

  def auth_headers(user)
    post '/api/v1/auth/login', params: { email: user.email, password: 'password123' }, headers: { 'X-Tenant-Slug' => user.company.slug }
    { 'Authorization' => "Bearer #{response.parsed_body['token']}" }
  end

  def courier(name, uri)
    service = Service.create!(service_name: name, type: 'courier', http_method: 'POST', uri: uri,
                              request_mapper: { 'cp' => 'destination_zip_code' },
                              response_mapper: { 'precio' => 'shipping_cost',
                                                 'dias' => 'estimated_days' },
                              request_value_mapper: {}, response_value_mapper: {})
    CompanyIntegration.create!(company: company, service: service,
                               credentials: { 'access_token' => 'T' }, is_active: true)
  end

  def quote(warehouse_id: warehouse.id, order_id: order.id, auth: headers)
    post "/api/v1/orders/#{order_id}/quotes",
         params: { quote: { origin_warehouse_id: warehouse_id } }, headers: auth, as: :json
  end

  it 'returns 401 without a token' do
    post "/api/v1/orders/#{order.id}/quotes",
         params: { quote: { origin_warehouse_id: warehouse.id } }, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  context 'with a courier that answers' do
    before do
      courier('Fast', 'https://fast.test/rates')
      stub_request(:post, 'https://fast.test/rates')
        .to_return(status: 200, body: { precio: 2500.0, dias: 3 }.to_json)
      quote
    end

    it 'returns 200' do
      expect(response).to have_http_status(:ok)
    end

    it 'returns the normalized options', :aggregate_failures do
      option = response.parsed_body['data'].first
      expect(option['provider_name']).to eq('Fast')
      expect(option['shipping_cost'].to_f).to eq(2500.0)
      expect(option['estimated_days']).to eq(3)
    end
  end

  # Sin opciones no es un error: el front distingue "ningún operador contestó"
  # de "falló la cotización", y un 500 le sacaría esa diferencia.
  it 'returns 200 with an empty list when every courier fails' do
    courier('Broken', 'https://broken.test/rates')
    stub_request(:post, 'https://broken.test/rates').to_return(status: 500)
    quote

    expect(response.parsed_body['data']).to eq([])
  end

  it 'returns 200 with an empty list when the company has no couriers' do
    quote
    expect(response).to have_http_status(:ok)
  end

  describe 'tenant isolation' do
    def foreign
      @foreign ||= Current.set(company_id: nil) do
        other = Company.create!(name: 'Tenant B', tax_id: '30-22222222-2')
        { order: Order.create!(company: other, customer_name: 'B'),
          warehouse: Warehouse.create!(company: other, name: 'W', zip_code: '1', address: 'x') }
      end
    end

    it 'returns 404 for an order of another company' do
      quote(order_id: foreign[:order].id)
      expect(response).to have_http_status(:not_found)
    end

    it 'returns 404 for a warehouse of another company' do
      quote(warehouse_id: foreign[:warehouse].id)
      expect(response).to have_http_status(:not_found)
    end
  end

  it 'returns 400 without the origin warehouse' do
    post "/api/v1/orders/#{order.id}/quotes", params: {}, headers: headers, as: :json
    expect(response).to have_http_status(:bad_request)
  end

  # El valor presente pero vacio llegaba a Warehouse.find('') y salia como 404,
  # que le dice al cliente "ese deposito no existe" cuando en realidad no mando
  # ninguno. Detectado en el review del PR #60.
  it 'returns 400 when the origin warehouse is blank' do
    post "/api/v1/orders/#{order.id}/quotes",
         params: { quote: { origin_warehouse_id: '' } }, headers: headers, as: :json

    expect(response).to have_http_status(:bad_request)
  end
end
