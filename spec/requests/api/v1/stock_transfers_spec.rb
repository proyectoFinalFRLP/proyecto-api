# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Stock transfers API', type: :request do
  let(:company) { Company.create!(name: 'Tenant A', tax_id: '30-11111111-1') }
  let(:user) { User.create!(email: 'a@example.com', password: 'password123', company: company) }
  let(:headers) { auth_headers(user) }
  let(:product) { Product.create!(company: company, sku: 'A-001', name: 'Alpha') }

  def auth_headers(user)
    post '/api/v1/auth/login', params: { email: user.email, password: 'password123' }, headers: { 'X-Tenant-Slug' => user.company.slug }
    { 'Authorization' => "Bearer #{response.parsed_body['token']}" }
  end

  def warehouse(name, zip)
    Warehouse.create!(company: company, name: name, zip_code: zip, address: "Calle #{zip}")
  end

  def origin = @origin ||= warehouse('Central', '1900')
  def destination = @destination ||= warehouse('North', '1901')

  def body_for(quantity)
    { stock_transfer: { product_id: product.id, origin_warehouse_id: origin.id,
                        destination_warehouse_id: destination.id, quantity: quantity } }
  end

  # El tenant se fuerza a nil para que el fixture nazca SIEMPRE en la otra
  # empresa: assign_current_company pisaría el company: manual si Current
  # quedó seteado por un request previo.
  def foreign_product
    @foreign_product ||= Current.set(company_id: nil) do
      other = Company.create!(name: 'Tenant B', tax_id: '30-22222222-2')
      Product.create!(company: other, sku: 'B-001', name: 'Other')
    end
  end

  def dispatch_one(quantity: 4)
    Stock.find_or_create_by!(product: product, warehouse: origin) { |s| s.quantity = 10 }
    Catalog::DispatchTransfer.new(company: company, product: product, origin_warehouse: origin,
                                  destination_warehouse: destination, quantity: quantity).call
  end

  describe 'POST /api/v1/stock-transfers' do
    before { Stock.create!(product: product, warehouse: origin, quantity: 10) }

    it 'returns 401 without a token' do
      post '/api/v1/stock-transfers', params: body_for(4), as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it 'creates the transfer', :aggregate_failures do
      post '/api/v1/stock-transfers', params: body_for(4), headers: headers, as: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body['status']).to eq('in_transit')
    end

    it 'returns 422 when the origin cannot cover the quantity' do
      post '/api/v1/stock-transfers', params: body_for(99), headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'returns 422 when both ends are the same warehouse' do
      params = body_for(1).deep_merge(stock_transfer: { destination_warehouse_id: origin.id })
      post '/api/v1/stock-transfers', params: params, headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'returns 404 for a product of another company' do
      params = body_for(1).deep_merge(stock_transfer: { product_id: foreign_product.id })
      post '/api/v1/stock-transfers', params: params, headers: headers, as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'GET /api/v1/stock-transfers' do
    it 'lists the transfers of the company' do
      dispatch_one
      get '/api/v1/stock-transfers', headers: headers

      expect(response.parsed_body['data'].length).to eq(1)
    end

    it 'filters by status' do
      dispatch_one
      get '/api/v1/stock-transfers', params: { status: 'received' }, headers: headers

      expect(response.parsed_body['data']).to be_empty
    end
  end

  describe 'POST /api/v1/stock-transfers/:id/receive' do
    it 'settles the transfer into the destination', :aggregate_failures do
      transfer = dispatch_one
      post "/api/v1/stock-transfers/#{transfer.id}/receive", headers: headers

      expect(response).to have_http_status(:ok)
      expect(Stock.find_by(product: product, warehouse: destination).quantity).to eq(4)
    end

    it 'returns 409 when it is no longer in flight' do
      transfer = dispatch_one
      Catalog::SettleTransfer.new(transfer: transfer, outcome: :received).call
      post "/api/v1/stock-transfers/#{transfer.id}/receive", headers: headers

      expect(response).to have_http_status(:conflict)
    end
  end

  describe 'POST /api/v1/stock-transfers/:id/cancel' do
    it 'gives the units back to the origin', :aggregate_failures do
      transfer = dispatch_one
      post "/api/v1/stock-transfers/#{transfer.id}/cancel", headers: headers

      expect(response).to have_http_status(:ok)
      expect(Stock.find_by(product: product, warehouse: origin).quantity).to eq(10)
    end
  end
end
