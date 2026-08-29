# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Orders API', type: :request do
  let(:company) { Company.create!(name: "Acme-#{SecureRandom.hex(4)}", tax_id: "20-#{rand(10_000_000..99_999_999)}-#{rand(1000..9999)}") }
  let(:user) { User.create!(email: 'a@acme.com', password: 'pass123', company: company) }
  let(:headers) { auth_headers(user) }
  let(:product) { Product.create!(company: company, sku: 'SKU-001', name: 'Celular') }
  let(:warehouse) { Warehouse.create!(company: company, name: 'Central', zip_code: '1900', address: 'Av 1') }

  def auth_headers(user)
    post '/api/v1/auth/login', params: { email: user.email, password: 'pass123' }
    { 'Authorization' => "Bearer #{response.parsed_body['token']}" }
  end

  before do
    Current.company_id = company.id
    Stock.create!(product: product, warehouse: warehouse, quantity: 20)
  end

  def build_payload(items: nil, **order_attrs)
    {
      order: {
        customer_name: 'Juan Pérez',
        customer_document: '12345678',
        items: items || [
          {
            product_id: product.id,
            warehouse_id: warehouse.id,
            quantity: 2,
            unit_price: 150.00
          }
        ]
      }.merge(order_attrs)
    }
  end

  describe 'POST /api/v1/orders' do
    it 'returns 401 without a token' do
      post '/api/v1/orders', params: build_payload, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    context 'when authenticated' do
      it 'creates an order and returns 201' do
        expect do
          post '/api/v1/orders', params: build_payload, headers: headers, as: :json
        end.to change(Order, :count).by(1)

        expect(response).to have_http_status(:created)
        expect(OrderItem.count).to eq(1)
      end

      it 'returns the order with items' do
        post '/api/v1/orders', params: build_payload, headers: headers, as: :json

        body = response.parsed_body
        expect(body['customer_name']).to eq('Juan Pérez')
        expect(body['order_items'].first['quantity']).to eq(2)
      end

      it 'deducts stock from the specified warehouse' do
        post '/api/v1/orders', params: build_payload, headers: headers, as: :json

        expect(Stock.find_by(product: product, warehouse: warehouse).quantity).to eq(18)
      end

      it 'assigns the company from the JWT' do
        post '/api/v1/orders', params: build_payload, headers: headers, as: :json

        expect(Order.last.company_id).to eq(company.id)
      end

      it 'rejects when stock is insufficient' do
        items = [{ product_id: product.id, warehouse_id: warehouse.id,
                   quantity: 50, unit_price: 10.00 }]
        post '/api/v1/orders', params: build_payload(items: items),
             headers: headers, as: :json

        expect(response).to have_http_status(:unprocessable_content)
      end

      it 'rejects when warehouse belongs to another company' do
        other_company = Company.create!(name: 'Other', tax_id: "30-#{rand(10_000_000..99_999_999)}-0001")
        Current.set(company_id: nil) do
          other_wh = Warehouse.create!(company: other_company, name: 'Other',
                                       zip_code: '2000', address: 'X')
          items = [{ product_id: product.id, warehouse_id: other_wh.id,
                     quantity: 1, unit_price: 10.00 }]
          post '/api/v1/orders', params: build_payload(items: items),
               headers: headers, as: :json
        end

        expect(response).to have_http_status(:unprocessable_content)
      end

      it 'rejects when items is not an array' do
        post '/api/v1/orders',
             params: { order: { customer_name: 'X', items: 'not_an_array' } },
             headers: headers, as: :json

        expect(response).to have_http_status(:unprocessable_content)
      end

      it 'rejects when items is empty' do
        post '/api/v1/orders',
             params: { order: { customer_name: 'X', items: [] } },
             headers: headers, as: :json

        expect(response).to have_http_status(:unprocessable_content)
      end

      it 'does not create order when item validation fails' do
        items = [{ product_id: product.id, warehouse_id: warehouse.id,
                   quantity: 50, unit_price: 10 }]
        expect do
          post '/api/v1/orders', params: build_payload(items: items),
               headers: headers, as: :json
        end.not_to change(Order, :count)
      end

      it 'handles multiple items in a single order' do
        product2 = Product.create!(company: company, sku: "SKU-#{rand(100..999)}", name: 'Tablet')
        Stock.create!(product: product2, warehouse: warehouse, quantity: 10)

        items = [
          { product_id: product.id, warehouse_id: warehouse.id,
            quantity: 3, unit_price: 150.00 },
          { product_id: product2.id, warehouse_id: warehouse.id,
            quantity: 1, unit_price: 300.00 }
        ]

        post '/api/v1/orders', params: build_payload(items: items),
             headers: headers, as: :json

        expect(response).to have_http_status(:created)
        expect(OrderItem.count).to eq(2)
      end
    end
  end
end
