# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Orders::CancelOrder, type: :poro do
  def company = @company ||= Company.create!(name: 'Acme', tax_id: '20-12345678-9')
  def product = @product ||= Product.create!(company: company, sku: 'CEL-1', name: 'Celular')
  def other_product = @other_product ||= Product.create!(company: company, sku: 'CEL-2', name: 'Funda')

  def central
    @central ||= Warehouse.create!(company: company, name: 'Central', zip_code: '1900',
                                   address: 'Av 1')
  end

  def norte
    @norte ||= Warehouse.create!(company: company, name: 'Norte', zip_code: '1602', address: 'Av 2')
  end

  # Dos líneas de depósitos distintos: 4 celulares de Central (queda en 20) y 3
  # fundas de Norte (queda en 7).
  let(:order) do
    Orders::CreateOrder.new(
      params: { customer_name: 'Juan Pérez' },
      items: [{ product_id: product.id, warehouse_id: central.id, quantity: 4, unit_price: 100 },
              { product_id: other_product.id, warehouse_id: norte.id, quantity: 3, unit_price: 10 }],
      company: company
    ).call
  end

  before do
    Current.company_id = company.id
    Stock.create!(product: product, warehouse: central, quantity: 24)
    Stock.create!(product: other_product, warehouse: norte, quantity: 10)
    order
  end

  def cancel(expected_version: nil)
    described_class.new(order: order, expected_version: expected_version).call
  end

  def stock(product, warehouse) = Stock.find_by(product: product, warehouse: warehouse).quantity

  it 'marks the order as cancelled' do
    expect(cancel.reload.status).to eq('cancelled')
  end

  it 'gives every line back to the warehouse it was taken from', :aggregate_failures do
    cancel

    expect(stock(product, central)).to eq(24)
    expect(stock(other_product, norte)).to eq(10)
  end

  # El `after_commit` de Stock es el que publica en los canales: no hay que
  # encolar nada a mano.
  it 'lets the stock change reach the sales channels' do
    expect { cancel }.to have_enqueued_job(Catalog::SyncStockToChannelsJob).twice
  end

  it 'refuses an order that is already cancelled, and gives nothing back twice', :aggregate_failures do
    cancel

    expect { cancel }.to raise_error(Orders::OrderNotEditableError, /cancelled/)
    expect(stock(product, central)).to eq(24)
  end

  context 'when its shipment already left' do
    before do
      Shipment.create!(company: company, order: order, status: 'in_transit', tracking_number: 'T-1')
    end

    it 'refuses to cancel and moves no stock', :aggregate_failures do
      expect { cancel }.to raise_error(Orders::OrderNotEditableError, /in_transit/)
      expect(order.reload.status).to eq('pending')
      expect(stock(product, central)).to eq(20)
    end
  end

  # Abierto pero sin despachar: `ConfirmDispatch` ya no lo va a despachar.
  it 'cancels an order whose shipment was opened but not dispatched' do
    Shipment.create!(company: company, order: order, status: 'pending')

    expect(cancel.reload.status).to eq('cancelled')
  end

  # Anterior a TESIS-126: no hay a dónde devolver, y adivinar es peor.
  context 'when a line does not record its warehouse' do
    before { order.order_items.first.update_column(:warehouse_id, nil) } # rubocop:disable Rails/SkipsModelValidations

    it 'refuses to cancel and leaves everything as it was', :aggregate_failures do
      expect { cancel }.to raise_error(ActiveRecord::RecordNotSaved, /does not record the warehouse/)
      expect(order.reload.status).to eq('pending')
      expect(stock(other_product, norte)).to eq(7)
    end
  end

  it 'refuses a stale version' do
    expect { cancel(expected_version: 'stale') }.to raise_error(Orders::StaleOrderError)
  end

  it 'accepts the current version' do
    version = Orders::OrderVersion.new(order: order).call

    expect(cancel(expected_version: version).status).to eq('cancelled')
  end
end
