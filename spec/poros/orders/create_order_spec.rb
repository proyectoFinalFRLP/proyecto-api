# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Orders::CreateOrder, type: :poro do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:product) { Product.create!(company: company, sku: 'SKU-001', name: 'Celular') }
  let(:warehouse) { Warehouse.create!(company: company, name: 'Central', zip_code: '1900', address: 'Av 1') }
  let(:params) { { customer_name: 'Juan Pérez' } }

  before do
    Current.company_id = company.id
    Stock.create!(product: product, warehouse: warehouse, quantity: 20)
  end

  def item(overrides = {})
    { product_id: product.id, warehouse_id: warehouse.id,
      quantity: 2, unit_price: 150.00 }.merge(overrides)
  end

  def create_order(items)
    described_class.new(params: params, items: items, company: company).call
  end

  # product2 se crea después que product, así que su id es mayor.
  # Mandarlo primero deja el input en orden inverso al de adquisición de locks.
  def reverse_ordered_items
    [item(product_id: product2.id, quantity: 1, unit_price: 300.00),
     item(product_id: product.id, quantity: 3)]
  end

  def stub_lock_acquisition(collector)
    allow(Catalog::WithStockLock).to receive(:new)
      .and_wrap_original do |original, **kwargs|
      collector << kwargs[:product_id]
      original.call(**kwargs) { nil }
    end
  end

  def other_company_warehouse
    other_co = Company.create!(name: 'Other', tax_id: '30-99999999-9')
    Current.set(company_id: nil) do
      Warehouse.create!(company: other_co, name: 'Other', zip_code: '2000', address: 'X')
    end
  end

  # Memoizado (a diferencia de other_company_warehouse): un mismo ejemplo lo
  # usa dos veces — en attempt_order_with_foreign_product y en la aserción — y
  # sin el @, cada llamada crearía una Company con el mismo tax_id y chocaría.
  def other_company_product
    @other_company_product ||= Current.set(company_id: nil) do
      other_co = Company.create!(name: 'Other', tax_id: '30-99999999-8')
      Product.create!(company: other_co, sku: 'SKU-FOREIGN', name: 'Ajeno')
    end
  end

  # Corre create_order con un producto de otra empresa suprimiendo el error:
  # deja el camino ejecutado para poder inspeccionar qué locks se tomaron.
  def attempt_order_with_foreign_product(locked)
    stub_lock_acquisition(locked)
    suppress(ActiveRecord::RecordNotSaved) do
      create_order([item(product_id: other_company_product.id)])
    end
  end

  describe 'successful creation' do
    subject(:order) { create_order([item]) }

    it 'creates the order with status pending', :aggregate_failures do
      expect(order).to be_persisted
      expect(order.status).to eq('pending')
    end

    it 'assigns the company from context' do
      expect(order.company_id).to eq(company.id)
    end

    it 'creates order items' do
      expect { order }.to change(OrderItem, :count).by(1)
    end

    it 'deducts stock from the specified warehouse' do
      expect { order }.to change {
        warehouse.stocks.find_by(product: product).quantity
      }.from(20).to(18)
    end

    it 'returns the order' do
      expect(order).to be_a(Order)
    end
  end

  describe 'multiple items' do
    let(:product2) { Product.create!(company: company, sku: 'SKU-002', name: 'Tablet') }

    before { Stock.create!(product: product2, warehouse: warehouse, quantity: 10) }

    it 'creates all items' do
      items = [item(product_id: product.id, quantity: 3),
               item(product_id: product2.id, quantity: 1, unit_price: 300.00)]
      expect { create_order(items) }.to change(OrderItem, :count).by(2)
    end

    it 'deducts stock for each item' do
      items = [item(product_id: product.id, quantity: 3),
               item(product_id: product2.id, quantity: 1, unit_price: 300.00)]
      create_order(items)
      expect(Stock.find_by(product: product, warehouse: warehouse).quantity).to eq(17)
    end

    it 'acquires locks in ascending product_id order regardless of input order' do
      locked = []
      stub_lock_acquisition(locked)
      create_order(reverse_ordered_items)
      expect(locked.first(2)).to eq([product.id, product2.id])
    end

    # La clave del advisory lock no lleva tenant (WithStockLock#lock_key), así
    # que tomar locks antes de validar pertenencia dejaría que un request
    # nombre un product_id ajeno y bloquee las escrituras legítimas de esa
    # empresa con 409 mientras esta transacción viva.
    it 'rejects a product of another company before acquiring locks' do
      foreign = other_company_product
      locked = []
      stub_lock_acquisition(locked)

      expect { create_order([item(product_id: foreign.id)]) }
        .to raise_error(ActiveRecord::RecordNotSaved)
    end

    it 'never takes the lock of a product from another company' do
      locked = []
      attempt_order_with_foreign_product(locked)

      expect(locked).not_to include(other_company_product.id)
    end

    it 'persists items in input order, not lock order' do
      order = create_order(reverse_ordered_items)
      expect(order.order_items.map(&:product_id)).to eq([product2.id, product.id])
    end
  end

  describe 'transactional rollback' do
    it 'rolls back when stock is insufficient' do
      expect { create_order([item(quantity: 50)]) }
        .to raise_error(Catalog::InsufficientStockError)
    end

    it 'leaves order count unchanged on stock failure' do
      suppress(Catalog::InsufficientStockError) { create_order([item(quantity: 50)]) }
      expect(Order.count).to eq(0)
    end

    it 'rolls back when product does not exist' do
      expect { create_order([item(product_id: -1)]) }
        .to raise_error(ActiveRecord::RecordNotSaved,
                        'product_id -1 does not exist')
    end

    it 'rolls back when warehouse belongs to another company' do
      other_wh = other_company_warehouse
      expect { create_order([item(warehouse_id: other_wh.id)]) }
        .to raise_error(ActiveRecord::RecordNotSaved)
    end
  end

  describe 'validation' do
    it 'raises when items is blank' do
      expect { described_class.new(params: params, items: [], company: company).call }
        .to raise_error(ActiveRecord::RecordNotSaved, /items must be present/)
    end

    it 'raises when a required field is missing from an item' do
      expect { create_order([item(quantity: nil)]) }
        .to raise_error(ActiveRecord::RecordNotSaved, /quantity is required/)
    end
  end
end
