# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Orders API', type: :request do
  let(:company) do
    Company.create!(name: 'Acme', tax_id: '20-12345678-9')
  end
  let(:user) { User.create!(email: 'a@acme.com', password: 'pass123', company: company) }
  let(:headers) { auth_headers(user) }
  let(:product) { Product.create!(company: company, sku: 'SKU-001', name: 'Celular') }
  let(:warehouse) do
    Warehouse.create!(company: company, name: 'Central',
                      zip_code: '1900', address: 'Av 1')
  end

  def auth_headers(user)
    post '/api/v1/auth/login', params: { email: user.email, password: 'pass123' }
    { 'Authorization' => "Bearer #{response.parsed_body['token']}" }
  end

  before do
    Current.company_id = company.id
    Stock.create!(product: product, warehouse: warehouse, quantity: 20)
  end

  def default_item
    { product_id: product.id, warehouse_id: warehouse.id,
      quantity: 2, unit_price: 150.00 }
  end

  def build_payload(items: nil)
    { order: { customer_name: 'Juan Pérez', customer_document: '12345678',
               items: items || [default_item] } }
  end

  def post_order(payload = build_payload)
    post '/api/v1/orders', params: payload, headers: headers, as: :json
  end

  def create_second_product
    p2 = Product.create!(company: company, sku: 'SKU-002', name: 'Tablet')
    Stock.create!(product: p2, warehouse: warehouse, quantity: 10)
    p2
  end

  def multi_item_payload(prod1, prod2)
    [
      { product_id: prod1.id, warehouse_id: warehouse.id,
        quantity: 3, unit_price: 150.00 },
      { product_id: prod2.id, warehouse_id: warehouse.id,
        quantity: 1, unit_price: 300.00 }
    ]
  end

  def other_company_warehouse
    other_co = Company.create!(name: 'Other', tax_id: '30-99999999-0')
    Current.set(company_id: nil) do
      Warehouse.create!(company: other_co, name: 'Other',
                        zip_code: '2000', address: 'X')
    end
  end

  describe 'POST /api/v1/orders' do
    it 'returns 401 without a token' do
      post '/api/v1/orders', params: build_payload, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    context 'when authenticated' do
      it 'returns 201' do
        post_order
        expect(response).to have_http_status(:created)
      end

      it 'persists the order' do
        expect { post_order }.to change(Order, :count).by(1)
      end

      it 'returns customer_name in the body' do
        post_order
        expect(response.parsed_body['customer_name']).to eq('Juan Pérez')
      end

      it 'returns status pending in the body' do
        post_order
        expect(response.parsed_body['status']).to eq('pending')
      end

      it 'returns unit_price as a number' do
        post_order
        expect(response.parsed_body.dig('order_items', 0, 'unit_price')).to eq(150.0)
      end

      it 'deducts stock from the specified warehouse' do
        post_order
        expect(Stock.find_by(product: product, warehouse: warehouse).quantity).to eq(18)
      end

      it 'returns unit_price as a number, not a string' do
        post_order
        item = response.parsed_body['order_items'].first
        expect(item['unit_price']).to be_a(Numeric)
      end

      it 'assigns the company from the JWT' do
        post_order
        expect(Order.last.company_id).to eq(company.id)
      end

      it 'rejects when stock is insufficient' do
        post_order(build_payload(items: [default_item.merge(quantity: 50, unit_price: 10.00)]))
        expect(response).to have_http_status(:unprocessable_content)
      end

      it 'rejects when warehouse belongs to another company' do
        other_wh = other_company_warehouse
        post_order(build_payload(items: [default_item.merge(warehouse_id: other_wh.id)]))
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
        expect { post_order(build_payload(items: [default_item.merge(quantity: 50)])) }
          .not_to change(Order, :count)
      end

      it 'handles multiple items in a single order', :aggregate_failures do
        product2 = create_second_product
        post_order(build_payload(items: multi_item_payload(product, product2)))
        expect(response).to have_http_status(:created)
      end
    end
  end
end
