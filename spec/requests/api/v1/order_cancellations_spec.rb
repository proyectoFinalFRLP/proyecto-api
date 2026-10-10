# frozen_string_literal: true

require 'rails_helper'

# POST /api/v1/orders/:id/cancel. Las reglas de la devolución de stock se prueban
# en el spec de Orders::CancelOrder; acá, el contrato HTTP.
RSpec.describe 'Order cancellations API', type: :request do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:user) { User.create!(email: 'a@acme.com', password: 'pass123', company: company) }
  let(:headers) { auth_headers(user) }

  def auth_headers(user)
    post '/api/v1/auth/login', params: { email: user.email, password: 'pass123' },
                               headers: { 'X-Tenant-Slug' => user.company.slug }
    { 'Authorization' => "Bearer #{response.parsed_body['token']}" }
  end

  def product = @product ||= Product.create!(company: company, sku: 'CEL-1', name: 'Celular')

  def warehouse
    @warehouse ||= Warehouse.create!(company: company, name: 'Central', zip_code: '1900',
                                     address: 'Av 1')
  end

  def order
    @order ||= begin
      Stock.create!(product: product, warehouse: warehouse, quantity: 24)
      Orders::CreateOrder.new(
        params: { customer_name: 'Juan Pérez' },
        items: [{ product_id: product.id, warehouse_id: warehouse.id, quantity: 4, unit_price: 100 }],
        company: company
      ).call
    end
  end

  def cancel(target = order, if_match: nil)
    extra = if_match ? { 'If-Match' => %("#{if_match}") } : {}
    post "/api/v1/orders/#{target.id}/cancel", headers: headers.merge(extra)
  end

  def stock_left = Stock.find_by(product: product, warehouse: warehouse).quantity

  it 'returns 401 without a token' do
    post "/api/v1/orders/#{order.id}/cancel"

    expect(response).to have_http_status(:unauthorized)
  end

  it 'answers 200 with the cancelled order and gives its units back', :aggregate_failures do
    cancel

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['status']).to eq('cancelled')
    expect(stock_left).to eq(24)
  end

  it 'answers the new version, so the client can keep working without a reload' do
    cancel

    expect(response.headers['ETag']).to eq(%("#{Orders::OrderVersion.new(order: order.reload).call}"))
  end

  it 'answers 409 when the order is already cancelled', :aggregate_failures do
    cancel
    cancel

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body['error']).to eq('a cancelled order cannot be modified')
  end

  it 'answers 409 when its shipment already left' do
    Shipment.create!(company: company, order: order, status: 'in_transit', tracking_number: 'T-1')

    cancel

    expect(response).to have_http_status(:conflict)
  end

  it 'answers 412 to a stale If-Match and cancels nothing', :aggregate_failures do
    cancel(if_match: 'stale')

    expect(response).to have_http_status(:precondition_failed)
    expect(order.reload.status).to eq('pending')
  end

  it 'answers 404 for an order of another company' do
    other = Company.create!(name: 'Otra', tax_id: '30-99999999-9')
    foreign = Current.set(company_id: other.id) { Order.create!(company: other, customer_name: 'X') }

    cancel(foreign)

    expect(response).to have_http_status(:not_found)
  end

  it 'answers 409 when another operation holds the stock of the product' do
    order
    allow(Catalog::WithStockLock).to receive(:new)
      .and_raise(Catalog::LockTimeoutError.new(product_id: product.id, lock_key: 1))

    cancel

    expect(response).to have_http_status(:conflict)
  end
end
