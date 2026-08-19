# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Orders::ProcessWebhookOrder, type: :poro do
  subject(:process) { described_class.new(webhook_log: log) }

  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:integration) { CompanyIntegration.create!(company: company, service: create_service) }
  let(:payload) { order_payload(items: [line('MLA-1', 2, 1500.5), line('MLA-2', 1, 300)]) }
  let(:log) { create_log }

  # Plantilla del canal: describe dónde vive cada dato de la venta dentro del
  # payload externo. El marcador `[]` marca la lista de ítems.
  def order_mapper
    { 'id' => 'external_order_id', 'status' => 'status',
      'buyer.nickname' => 'customer_name', 'buyer.doc_number' => 'customer_document',
      'shipping.address.street' => 'customer_address',
      'shipping.address.zip_code' => 'customer_zip_code',
      'order_items[].item.id' => 'external_product_id',
      'order_items[].quantity' => 'quantity', 'order_items[].unit_price' => 'unit_price' }
  end

  def create_service(mapper: order_mapper)
    Service.create!(service_name: "Mercado Libre #{SecureRandom.hex(4)}", type: 'ecommerce',
                    http_method: 'GET', uri: 'https://api.ml.test/orders',
                    response_mapper: mapper, response_value_mapper: { 'pagado' => 'paid' })
  end

  def order_payload(items:, id: 'ML-1001', status: 'pagado')
    { 'id' => id, 'status' => status,
      'buyer' => { 'nickname' => 'Comprador ML', 'doc_number' => '20-30123456-7' },
      'shipping' => { 'address' => { 'street' => 'Av. Rivadavia 1234', 'zip_code' => '1406' } },
      'order_items' => items }
  end

  def line(external_id, quantity, unit_price = nil)
    { 'item' => { 'id' => external_id }, 'quantity' => quantity,
      'unit_price' => unit_price }.compact
  end

  def warehouse(name = 'Central')
    Warehouse.find_or_create_by!(company: company, name: name) do |w|
      w.zip_code = '1900'
      w.address = "#{name} 1"
    end
  end

  # Setup mínimo para que un ítem del webhook se pueda resolver: producto
  # interno, stock en un depósito y mapeo de identidad contra el canal.
  def publish(sku, external_id, stock: 10, price: nil, on: integration)
    product = Product.create!(company: company, sku: sku, name: "Producto #{sku}")
    Stock.create!(product: product, warehouse: warehouse, quantity: stock)
    ProductMapping.create!(product: product, company_integration: on,
                           external_product_id: external_id, external_price: price)
    product
  end

  def stock_of(sku) = Stock.find_by(product: Product.find_by(sku: sku)).quantity

  def create_log(body = payload)
    WebhookLog.create!(company_id: company.id, company_integration: integration, payload: body)
  end

  before { Current.company_id = company.id }

  context 'when every item of the sale is mapped and has stock' do
    before { publish('SKU-1', 'MLA-1') && publish('SKU-2', 'MLA-2') }

    it 'creates the order with the customer data translated by the template',
       :aggregate_failures do
      expect(process.call).to have_attributes(
        external_order_id: 'ML-1001', customer_name: 'Comprador ML',
        customer_document: '20-30123456-7', customer_address: 'Av. Rivadavia 1234',
        customer_zip_code: '1406'
      )
    end

    it 'links the order to the integration that received the webhook' do
      expect(process.call.company_integration).to eq(integration)
    end

    it 'translates the external status with the value mapper' do
      expect(process.call.status).to eq('paid')
    end

    it 'creates one item per line of the sale' do
      expect { process.call }.to change(OrderItem, :count).by(2)
    end

    it 'resolves each line to its internal product', :aggregate_failures do
      items = process.call.order_items.includes(:product).index_by { |item| item.product.sku }
      expect(items['SKU-1']).to have_attributes(quantity: 2, unit_price: 1500.5)
      expect(items['SKU-2']).to have_attributes(quantity: 1, unit_price: 300)
    end

    it 'deducts the exact quantity sold from the internal stock', :aggregate_failures do
      process.call
      expect(stock_of('SKU-1')).to eq(8)
      expect(stock_of('SKU-2')).to eq(9)
    end

    it 'marks the webhook log as processed' do
      expect { process.call }.to change { log.reload.status }.from('pending').to('processed')
    end

    it 'clears the error message of a previous failed attempt' do
      log.update!(status: :failed, error_message: 'boom')
      expect { process.call }.to change { log.reload.error_message }.to(nil)
    end
  end

  context 'when the sale includes a product that is not mapped' do
    before { publish('SKU-1', 'MLA-1') }

    it 'aborts with a descriptive error' do
      expect { process.call }.to raise_error(described_class::UnmappedProductError, /MLA-2/)
    end

    it 'does not create a partial order' do
      suppress(described_class::UnmappedProductError) { process.call }
      expect(Order.count).to eq(0)
    end

    it 'does not deduct stock from the item that was mapped' do
      suppress(described_class::UnmappedProductError) { process.call }
      expect(stock_of('SKU-1')).to eq(10)
    end

    it 'leaves the webhook log failed with the reason' do
      suppress(described_class::UnmappedProductError) { process.call }
      expect(log.reload).to have_attributes(status: 'failed', error_message: /is not mapped/)
    end
  end

  context 'when a product does not have enough stock' do
    before { publish('SKU-1', 'MLA-1') && publish('SKU-2', 'MLA-2', stock: 0) }

    it 'aborts the whole sale' do
      expect { process.call }.to raise_error(Catalog::InsufficientStockError, /SKU-2/)
    end

    it 'rolls back the order and its items', :aggregate_failures do
      suppress(Catalog::InsufficientStockError) { process.call }
      expect(Order.count).to eq(0)
      expect(OrderItem.count).to eq(0)
    end

    # El descuento del primer ítem ya estaba escrito cuando falló el segundo: es
    # el caso que prueba que todo corre dentro de una única transacción.
    it 'rolls back the stock already deducted for the previous item' do
      suppress(Catalog::InsufficientStockError) { process.call }
      expect(stock_of('SKU-1')).to eq(10)
    end

    it 'leaves the webhook log failed with the reason' do
      suppress(Catalog::InsufficientStockError) { process.call }
      expect(log.reload).to have_attributes(status: 'failed', error_message: /insufficient stock/)
    end
  end

  context 'when the same external sale arrives twice' do
    before do
      publish('SKU-1', 'MLA-1') && publish('SKU-2', 'MLA-2')
      described_class.new(webhook_log: create_log).call
    end

    it 'does not create a second order' do
      expect { process.call }.not_to change(Order, :count)
    end

    it 'does not deduct the stock twice' do
      expect { process.call }.not_to(change { stock_of('SKU-1') })
    end

    it 'marks the duplicate log as processed' do
      expect { process.call }.to change { log.reload.status }.to('processed')
    end
  end

  context 'when the log was already processed' do
    before { log.update!(status: :processed) }

    it 'does nothing' do
      expect { process.call }.not_to change(Order, :count)
    end
  end

  context 'when the payload cannot be translated' do
    before { publish('SKU-1', 'MLA-1') }

    it 'fails when the template finds no external order id' do
      log.update!(payload: payload.except('id'))
      expect { process.call }
        .to raise_error(described_class::InvalidPayloadError, /external order id/)
    end

    it 'fails when the sale carries no items' do
      log.update!(payload: order_payload(items: []))
      expect { process.call }.to raise_error(described_class::InvalidPayloadError, /item/)
    end

    it 'fails when an item has no usable quantity' do
      log.update!(payload: order_payload(items: [line('MLA-1', nil)]))
      expect { process.call }.to raise_error(described_class::InvalidPayloadError, /quantity/)
    end

    it 'writes nothing when an item has no usable quantity' do
      log.update!(payload: order_payload(items: [line('MLA-1', 0)]))
      suppress(described_class::InvalidPayloadError) { process.call }
      expect(Order.count).to eq(0)
    end
  end

  context 'when the template does not map the price of the items' do
    before { publish('SKU-1', 'MLA-1', price: 999.99) }

    let(:payload) { order_payload(items: [line('MLA-1', 1)]) }

    it 'falls back to the price published on the channel' do
      expect(process.call.order_items.first.unit_price).to eq(999.99)
    end
  end

  context 'when the channel reports a status the OMS does not know' do
    before { publish('SKU-1', 'MLA-1') }

    let(:payload) { order_payload(items: [line('MLA-1', 1)], status: 'en_camino') }

    it 'registers the sale as pending instead of losing it' do
      expect(process.call.status).to eq('pending')
    end
  end

  context 'when the external id is only mapped on another integration' do
    before do
      publish('SKU-1', 'MLA-1',
              on: CompanyIntegration.create!(company: company, service: create_service))
    end

    let(:payload) { order_payload(items: [line('MLA-1', 1)]) }

    it 'does not resolve a mapping of a different channel' do
      expect { process.call }.to raise_error(described_class::UnmappedProductError)
    end
  end
end
