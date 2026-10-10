# frozen_string_literal: true

require 'rails_helper'

# Una venta real de la tienda de prueba de Shopify (`orders/create`, capturada
# el 2026-10-01 y anonimizada) recorrida de punta a punta: gateway con firma,
# worker de ingesta y descuento de stock (ADR-019).
RSpec.describe 'Shopify orders/create', type: :request do
  include ActiveJob::TestHelper

  let(:company) { Company.create!(name: 'Norte', tax_id: '20-12345678-9') }
  let(:integration) do
    CompanyIntegration.create!(company: company, service: shopify, is_active: true,
                               credentials: { 'client_id' => 'CLIENT-ID',
                                              'client_secret' => 'shpss_SECRET' })
  end
  let(:product) { Product.create!(company: company, sku: 'NOR-002', name: 'Notebook') }

  # La plantilla tal como la siembra db/seeds.rb (sólo lo que usa la ingesta).
  def shopify
    @shopify ||= Service.create!(
      service_name: 'Shopify', type: 'ecommerce', http_method: 'POST',
      uri: 'https://:shop_domain/admin/api/2026-07/graphql.json', request_format: 'graphql',
      response_mapper: {
        'id' => 'external_order_id', 'financial_status' => 'status',
        'shipping_address.name' => 'customer_name',
        'shipping_address.address1' => 'customer_address',
        'shipping_address.zip' => 'customer_zip_code',
        'shipping_address.city' => 'customer_city',
        'shipping_address.province' => 'customer_province',
        'line_items[].variant_id' => 'external_product_id',
        'line_items[].quantity' => 'quantity', 'line_items[].price' => 'unit_price'
      },
      response_value_mapper: { 'authorized' => 'pending', 'voided' => 'cancelled' },
      webhook_config: { 'signature' => 'hmac_sha256_base64',
                        'signature_header' => 'X-Shopify-Hmac-SHA256',
                        'secret_key' => 'client_secret' }
    )
  end

  def body = Rails.root.join('spec/fixtures/shopify/orders_create.json').read

  def deliver(signature = Base64.strict_encode64(OpenSSL::HMAC.digest('SHA256', 'shpss_SECRET', body)))
    perform_enqueued_jobs(only: Orders::ProcessWebhookEventJob) do
      post "/api/webhooks/integrations/#{integration.id}",
           params: body, headers: { 'CONTENT_TYPE' => 'application/json',
                                    'X-Shopify-Topic' => 'orders/create',
                                    'X-Shopify-Hmac-SHA256' => signature }
    end
  end

  def order = Order.unscoped.find_by(external_order_id: '18922194698473')

  before do
    warehouse = Warehouse.create!(company: company, name: 'Central', address: 'Calle 1', zip_code: '1900')
    Stock.create!(product: product, warehouse: warehouse, quantity: 20)
    ProductMapping.create!(product: product, company_integration: integration,
                           external_product_id: '67579271348457')
  end

  it 'registers the sale with the customer and the address' do
    deliver
    expect(order).to have_attributes(status: 'paid', customer_name: 'Juana Pérez',
                                     customer_address: 'Calle 12 1234', customer_zip_code: '1131')
  end

  it 'keeps the city and the province for the courier' do
    deliver
    expect(order).to have_attributes(customer_city: 'Berisso', customer_province: 'Buenos Aires')
  end

  it 'adds up the lines into the total' do
    deliver
    expect(order.total_amount).to eq(1_450_000)
  end

  it 'resolves the line by its variant and deducts the stock' do
    deliver
    expect(Stock.unscoped.find_by(product: product).quantity).to eq(19)
  end

  it 'does not register the sale twice when Shopify retries the delivery', :aggregate_failures do
    2.times { deliver }
    expect(Order.unscoped.where(external_order_id: '18922194698473').count).to eq(1)
    expect(Stock.unscoped.find_by(product: product).quantity).to eq(19)
  end

  it 'rejects the delivery signed with another secret', :aggregate_failures do
    deliver(Base64.strict_encode64(OpenSSL::HMAC.digest('SHA256', 'shpss_OTHER', body)))
    expect(response).to have_http_status(:unauthorized)
    expect(order).to be_nil
  end
end
