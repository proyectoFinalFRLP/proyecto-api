# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Orders::ReplaceOrderLines, type: :poro do
  def company = @company ||= Company.create!(name: 'Acme', tax_id: '20-12345678-9')
  def central = @central ||= warehouse('Central', '1900')
  def norte = @norte ||= warehouse('Norte', '1901')
  def celular = @celular ||= Product.create!(company: company, sku: 'CEL-1', name: 'Celular')
  def funda = @funda ||= Product.create!(company: company, sku: 'FUN-1', name: 'Funda')

  def warehouse(name, zip)
    Warehouse.create!(company: company, name: name, zip_code: zip, address: "#{name} 1")
  end

  # La orden nace por el alta real, así las líneas llegan con su depósito y el
  # stock ya descontado, que es el punto de partida de cualquier modificación.
  let(:order) do
    Orders::CreateOrder.new(
      params: { customer_name: 'Juan Pérez' },
      items: [{ product_id: celular.id, warehouse_id: central.id, quantity: 4, unit_price: 100 }],
      company: company
    ).call
  end

  let(:line) { order.order_items.sole }

  # Central arranca con 24 celulares y el alta se lleva 4: cada ejemplo parte de
  # 20 en el depósito y una línea de 4 en la orden.
  before do
    Current.company_id = company.id
    Stock.create!(product: celular, warehouse: central, quantity: 24)
    Stock.create!(product: funda, warehouse: norte, quantity: 10)
    order
  end

  def stock(product, warehouse) = Stock.find_by(product: product, warehouse: warehouse).quantity

  def replace(items)
    described_class.new(order: order, items: items).call
  end

  def kept(quantity, **extra) = { id: line.id, quantity: quantity }.merge(extra)

  def new_line(product: funda, warehouse: norte, quantity: 2, unit_price: 50)
    { product_id: product.id, warehouse_id: warehouse.id, quantity: quantity, unit_price: unit_price }
  end

  describe 'a line whose quantity goes up' do
    it 'takes the difference from the warehouse of the line' do
      expect { replace([kept(7)]) }.to change { stock(celular, central) }.from(20).to(17)
    end

    it 'keeps the line with its new quantity' do
      replace([kept(7)])
      expect(line.reload.quantity).to eq(7)
    end

    it 'fails without touching anything when the warehouse cannot cover it', :aggregate_failures do
      expect { replace([kept(30)]) }.to raise_error(Catalog::InsufficientStockError)
      expect(stock(celular, central)).to eq(20)
    end
  end

  describe 'a line whose quantity goes down' do
    it 'gives the difference back to the warehouse of the line' do
      expect { replace([kept(1)]) }.to change { stock(celular, central) }.from(20).to(23)
    end
  end

  describe 'a line that stays the same' do
    it 'moves no stock' do
      expect { replace([kept(4)]) }.not_to(change { stock(celular, central) })
    end

    it 'takes no lock, since it competes with nobody' do
      allow(Catalog::WithStockLock).to receive(:new).and_call_original
      replace([kept(4)])
      expect(Catalog::WithStockLock).not_to have_received(:new)
    end

    # El precio de una línea existente es lo que se facturó (TESIS-114).
    it 'ignores a unit price sent for it' do
      replace([kept(4, unit_price: 1)])
      expect(line.reload.unit_price).to eq(100)
    end
  end

  describe 'a line that is not sent' do
    subject(:remove) { replace([new_line]) }

    it 'gives all its units back to its warehouse' do
      expect { remove }.to change { stock(celular, central) }.from(20).to(24)
    end

    it 'deletes the line' do
      removed_id = line.id
      remove
      expect(OrderItem.exists?(removed_id)).to be(false)
    end
  end

  describe 'a new line' do
    subject(:add) { replace([kept(4), new_line]) }

    it 'takes its units from the warehouse it names' do
      expect { add }.to change { stock(funda, norte) }.from(10).to(8)
    end

    it 'records that warehouse on the line', :aggregate_failures do
      add
      created = order.order_items.find_by(product: funda)
      expect(created).to have_attributes(warehouse_id: norte.id, quantity: 2, unit_price: 50)
    end

    it 'requires the four fields of an order line' do
      expect { replace([new_line.except(:warehouse_id)]) }
        .to raise_error(ActiveRecord::RecordNotSaved, 'item[0]: warehouse_id is required')
    end

    it 'treats an explicit null id as a new line' do
      expect { replace([kept(4), new_line.merge(id: nil)]) }.to change(OrderItem, :count).by(1)
    end
  end

  describe 'locks' do
    def record_locks(collector)
      allow(Catalog::WithStockLock).to receive(:new).and_wrap_original do |original, **kwargs|
        collector << kwargs[:product_id]
        original.call(**kwargs)
      end
    end

    it 'takes them in ascending product_id order, whatever the order of the request' do
      record_locks(locked = [])
      replace([new_line, kept(5)])
      expect(locked).to eq([celular.id, funda.id].sort)
    end
  end

  describe 'rejected requests, before any stock moves' do
    def expect_rejection(items, message)
      expect { replace(items) }.to raise_error(ActiveRecord::RecordNotSaved, message)
      expect(stock(celular, central)).to eq(20)
    end

    it 'rejects an order left with no lines' do
      expect_rejection([], 'an order needs at least one line')
    end

    it 'rejects a quantity that is not a positive integer', :aggregate_failures do
      expect_rejection([kept(0)], 'item[0]: quantity must be a positive integer')
      expect_rejection([kept(2.5)], 'item[0]: quantity must be a positive integer')
    end

    it 'rejects the same line sent twice' do
      expect_rejection([kept(4), kept(5)], 'the same line was sent twice')
    end

    it 'rejects a line of another order' do
      other = Order.create!(company: company, customer_name: 'Otra')
      foreign = OrderItem.create!(order: other, product: celular, quantity: 1, unit_price: 1)

      expect_rejection([{ id: foreign.id, quantity: 1 }], "line #{foreign.id} does not belong to this order")
    end

    it 'rejects a warehouse of another company' do
      alien = Current.set(company_id: nil) do
        other = Company.create!(name: 'Otra', tax_id: '30-99999999-9')
        Warehouse.create!(company: other, name: 'Ajeno', zip_code: '2000', address: 'X')
      end

      expect_rejection([kept(4), new_line(warehouse: alien)], 'One or more warehouses do not belong to this company')
    end

    it 'rejects a product that does not exist' do
      expect_rejection([kept(4), new_line.merge(product_id: 0)], 'product_id 0 does not exist')
    end
  end

  # Las líneas anteriores a TESIS-126 no registraron su depósito.
  describe 'a line that does not record its warehouse' do
    let!(:blind) { OrderItem.create!(order: order, product: funda, quantity: 3, unit_price: 50) }

    def blind_error
      "line #{blind.id} does not record the warehouse it was taken from: " \
        'its quantity cannot change and it cannot be removed'
    end

    it 'can stay as it is' do
      expect { replace([kept(4), { id: blind.id, quantity: 3 }]) }.not_to raise_error
    end

    it 'cannot change its quantity' do
      expect { replace([kept(4), { id: blind.id, quantity: 2 }]) }
        .to raise_error(ActiveRecord::RecordNotSaved, blind_error)
    end

    it 'cannot be removed' do
      expect { replace([kept(4)]) }.to raise_error(ActiveRecord::RecordNotSaved, blind_error)
    end
  end
end
