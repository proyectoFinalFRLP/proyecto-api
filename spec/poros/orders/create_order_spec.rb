# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Orders::CreateOrder, type: :poro do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:user) { User.create!(email: 'a@acme.com', password: 'pass123', company: company) }
  let(:product) { Product.create!(company: company, sku: 'SKU-001', name: 'Celular') }
  let(:warehouse) { Warehouse.create!(company: company, name: 'Central', zip_code: '1900', address: 'Av 1') }

  before do
    Current.company_id = company.id
    Stock.create!(product: product, warehouse: warehouse, quantity: 20)
  end

  def build_item(overrides = {})
    {
      product_id: product.id,
      warehouse_id: warehouse.id,
      quantity: 2,
      unit_price: 150.00
    }.merge(overrides)
  end

  def valid_params
    { customer_name: 'Juan Pérez' }
  end

  describe 'successful creation' do
    subject(:order) { described_class.new(params: valid_params, items: [build_item], company: company).call }

    it 'creates the order with status pending' do
      expect(order).to be_persisted
      expect(order.status).to eq('pending')
      expect(order.customer_name).to eq('Juan Pérez')
    end

    it 'assigns the company from context, not params' do
      expect(order.company_id).to eq(company.id)
    end

    it 'creates order items' do
      expect { order }.to change(OrderItem, :count).by(1)
      item = OrderItem.last
      expect(item.quantity).to eq(2)
      expect(item.unit_price).to eq(150.00)
    end

    it 'deducts stock from the specified warehouse' do
      expect { order }.to change { warehouse.stocks.find_by(product: product).quantity }.from(20).to(18)
    end

    it 'returns the order' do
      expect(order).to be_a(Order)
      expect(order.order_items.count).to eq(1)
    end
  end

  describe 'multiple items' do
    let(:product2) { Product.create!(company: company, sku: 'SKU-002', name: 'Tablet') }

    before do
      Stock.create!(product: product2, warehouse: warehouse, quantity: 10)
    end

    it 'creates all items and deducts stock for each' do
      items = [
        build_item(product_id: product.id, quantity: 3),
        build_item(product_id: product2.id, quantity: 1, unit_price: 300.00)
      ]

      order = described_class.new(params: valid_params, items: items, company: company).call

      expect(order.order_items.count).to eq(2)
      expect(Stock.find_by(product: product, warehouse: warehouse).quantity).to eq(17)
      expect(Stock.find_by(product: product2, warehouse: warehouse).quantity).to eq(9)
    end
  end

  describe 'transactional rollback' do
    it 'rolls back everything when stock is insufficient' do
      items = [build_item(quantity: 50)]

      expect do
        described_class.new(params: valid_params, items: items, company: company).call
      end.to raise_error(Catalog::InsufficientStockError)

      expect(Order.count).to eq(0)
      expect(OrderItem.count).to eq(0)
    end

    it 'rolls back everything when product does not exist' do
      items = [build_item(product_id: -1)]

      expect do
        described_class.new(params: valid_params, items: items, company: company).call
      end.to raise_error(ActiveRecord::RecordNotFound)

      expect(Order.count).to eq(0)
    end

    it 'rolls back everything when warehouse belongs to another company' do
      other_company = Company.create!(name: 'Other', tax_id: '30-99999999-9')
      Current.set(company_id: nil) do
        other_wh = Warehouse.create!(company: other_company, name: 'Other', zip_code: '2000', address: 'X')
        items = [build_item(warehouse_id: other_wh.id)]

        expect do
          described_class.new(params: valid_params, items: items, company: company).call
        end.to raise_error(ActiveRecord::RecordNotSaved)

        expect(Order.count).to eq(0)
      end
    end
  end

  describe 'validation' do
    it 'raises when items is blank' do
      expect do
        described_class.new(params: valid_params, items: [], company: company).call
      end.to raise_error(ActiveRecord::RecordNotSaved, /items must be present/)
    end

    it 'raises when a required field is missing from an item' do
      items = [build_item(quantity: nil)]

      expect do
        described_class.new(params: valid_params, items: items, company: company).call
      end.to raise_error(ActiveRecord::RecordNotSaved, /quantity is required/)
    end
  end
end
