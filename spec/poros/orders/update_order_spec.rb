# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Orders::UpdateOrder, type: :poro do
  def company = @company ||= Company.create!(name: 'Acme', tax_id: '20-12345678-9')
  def product = @product ||= Product.create!(company: company, sku: 'CEL-1', name: 'Celular')

  def warehouse
    @warehouse ||= Warehouse.create!(company: company, name: 'Central', zip_code: '1900',
                                     address: 'Av 1')
  end

  # La orden nace por el alta real: una línea de 4 a $100, con su depósito, y el
  # stock del depósito en 20 después del descuento.
  let(:order) do
    Orders::CreateOrder.new(
      params: { customer_name: 'Juan Pérez', customer_address: 'Calle 1' },
      items: [{ product_id: product.id, warehouse_id: warehouse.id, quantity: 4, unit_price: 100 }],
      company: company
    ).call
  end

  before do
    Current.company_id = company.id
    Stock.create!(product: product, warehouse: warehouse, quantity: 24)
    order
  end

  def update(params: {}, items: nil)
    described_class.new(order: order, params: params, items: items).call
  end

  def line = order.order_items.first

  def stock = Stock.find_by(product: product, warehouse: warehouse).quantity

  describe 'the data of the customer' do
    it 'updates the fields that come' do
      update(params: { customer_address: 'Av. Rivadavia 1234', customer_zip_code: '1406' })

      expect(order.reload).to have_attributes(customer_name: 'Juan Pérez',
                                              customer_address: 'Av. Rivadavia 1234',
                                              customer_zip_code: '1406')
    end
  end

  describe 'the status' do
    it 'moves from pending to paid' do
      update(params: { status: 'paid' })
      expect(order.reload.status).to eq('paid')
    end

    it 'moves back from paid to pending' do
      order.update!(status: 'paid')
      update(params: { status: 'pending' })
      expect(order.reload.status).to eq('pending')
    end

    # Cancelar devuelve el stock de la orden entera: no es una edición.
    it 'does not cancel the order', :aggregate_failures do
      expect { update(params: { status: 'cancelled' }) }
        .to raise_error(ActiveRecord::RecordNotSaved, 'status can only change to pending or paid')
      expect(order.reload.status).to eq('pending')
    end
  end

  describe 'the lines' do
    it 'leaves them alone when they do not come', :aggregate_failures do
      update(params: { customer_name: 'Otro' })

      expect(line.reload.quantity).to eq(4)
      expect(stock).to eq(20)
    end

    it 'replaces them when they come, moving the stock' do
      expect { update(items: [{ id: line.id, quantity: 6 }]) }.to change { stock }.from(20).to(18)
    end
  end

  describe 'the total' do
    it 'is recalculated from the resulting lines' do
      update(items: [{ id: line.id, quantity: 6 }])
      expect(order.reload.total_amount).to eq(600)
    end

    # TESIS-114: una orden vieja sin líneas tiene el total en NULL, y un 0 sería
    # indistinguible de una venta bonificada.
    it 'keeps the NULL of an old order without lines when the lines do not come' do
      old = Order.create!(company: company, customer_name: 'Vieja')
      described_class.new(order: old, params: { customer_name: 'Vieja S.A.' }).call

      expect(old.reload.total_amount).to be_nil
    end
  end

  describe 'orders that cannot be modified' do
    def expect_not_editable(message)
      expect { update(params: { customer_name: 'Otro' }) }
        .to raise_error(Orders::OrderNotEditableError, message)
      expect(order.reload.customer_name).to eq('Juan Pérez')
    end

    def ship(status:, tracking_number: nil)
      Shipment.create!(company: company, order: order, status: status,
                       tracking_number: tracking_number)
    end

    it 'rejects a cancelled order' do
      order.update!(status: 'cancelled')
      expect_not_editable('a cancelled order cannot be modified')
    end

    it 'rejects an order whose shipment is already on its way' do
      ship(status: 'in_transit')
      expect_not_editable("the order cannot be modified: its shipment is already 'in_transit'")
    end

    # El número de seguimiento lo asigna el courier al despachar (TESIS-47).
    it 'rejects an order whose pending shipment already has a tracking number' do
      ship(status: 'pending', tracking_number: 'AND-123')
      expect_not_editable(
        "the order cannot be modified: its shipment already has the tracking number 'AND-123'"
      )
    end

    it 'accepts an order whose shipment has not left yet' do
      ship(status: 'pending')
      expect { update(params: { customer_name: 'Otro' }) }.not_to raise_error
    end
  end

  # Locking optimista (TESIS-126), con el mismo mecanismo que productos.
  describe 'the expected version' do
    def version_seen = Orders::OrderVersion.new(order: Order.find(order.id)).call

    def update_with(version)
      described_class.new(order: Order.find(order.id), params: { customer_name: 'Otro' },
                          expected_version: version).call
    end

    it 'lets the update through when it is still the current one' do
      expect { update_with(version_seen) }.to change { order.reload.customer_name }.to('Otro')
    end

    it 'lets the update through when there is none, as HTTP does without If-Match' do
      expect { update_with(nil) }.to change { order.reload.customer_name }.to('Otro')
    end

    # Otro operador cambió una cantidad entre que esta pantalla leyó y guardó.
    context 'when someone changed the order after it was read' do
      subject(:stale_update) { update_with(seen) }

      let!(:seen) { version_seen }

      before { line.update!(quantity: 5) }

      it 'rejects the update, carrying the current version' do
        expect { stale_update }.to raise_error(
          an_object_having_attributes(class: Orders::StaleOrderError, current_version: version_seen)
        )
      end

      it 'leaves the order untouched' do
        suppress(Orders::StaleOrderError) { stale_update }
        expect(order.reload.customer_name).to eq('Juan Pérez')
      end
    end
  end

  # La razón de ser de la transacción: un fallo en cualquier línea no deja la
  # orden a medio modificar.
  describe 'when a line fails' do
    subject(:failed_update) do
      update(params: { customer_name: 'Otro' }, items: [{ id: line.id, quantity: 99 }])
    rescue Catalog::InsufficientStockError
      nil
    end

    it 'keeps the data of the customer' do
      failed_update
      expect(order.reload.customer_name).to eq('Juan Pérez')
    end

    it 'keeps the lines and the stock', :aggregate_failures do
      failed_update
      expect(line.reload.quantity).to eq(4)
      expect(stock).to eq(20)
    end
  end
end
