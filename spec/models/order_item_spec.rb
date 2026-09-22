# frozen_string_literal: true

require 'rails_helper'

RSpec.describe OrderItem, type: :model do
  subject(:order_item) do
    described_class.new(order: order, product: product, quantity: 2, unit_price: 150.00)
  end

  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:other_company) { Company.create!(name: 'Other Corp', tax_id: '30-99999999-9') }
  let(:order) { Order.create!(company: company, customer_name: 'Cliente ACME') }
  let(:product) { Product.create!(company: company, sku: 'SKU-001', name: 'Widget Alpha') }

  it 'is valid with required attributes' do
    expect(order_item).to be_valid
  end

  it 'defaults quantity to 1' do
    expect(described_class.new.quantity).to eq(1)
  end

  it 'is invalid without an order' do
    order_item.order = nil
    expect(order_item).not_to be_valid
  end

  it 'is invalid without a unit_price (NOT NULL snapshot)' do
    order_item.unit_price = nil
    expect(order_item).not_to be_valid
  end

  it 'is invalid without a product' do
    order_item.product = nil
    expect(order_item).not_to be_valid
  end

  it 'validates quantity is greater than zero' do
    order_item.quantity = 0
    expect(order_item).not_to be_valid
  end

  it 'validates unit_price is not negative' do
    order_item.unit_price = -1
    expect(order_item).not_to be_valid
  end

  it 'rejects a product from a different company', :aggregate_failures do
    order_item.product = Product.create!(company: other_company, sku: 'SKU-999',
                                         name: 'Widget Ajeno')
    expect(order_item).not_to be_valid
    expect(order_item.errors[:base]).to include('product must belong to the same company as the order')
  end

  it 'belongs to an order' do
    expect(described_class.reflect_on_association(:order).macro).to eq(:belongs_to)
  end

  it 'belongs to a product' do
    expect(described_class.reflect_on_association(:product).macro).to eq(:belongs_to)
  end

  # TESIS-126: la línea recuerda de qué depósito salió.
  describe 'warehouse' do
    let(:warehouse) do
      Warehouse.create!(company: company, name: 'Central', zip_code: '1900', address: 'Av 1')
    end

    it 'is valid without one, as the lines recorded before it existed' do
      order_item.warehouse = nil
      expect(order_item).to be_valid
    end

    it 'accepts a warehouse of the company of the order' do
      order_item.warehouse = warehouse
      expect(order_item).to be_valid
    end

    def foreign_warehouse
      Current.set(company_id: nil) do
        Warehouse.create!(company: other_company, name: 'Ajeno', zip_code: '2000', address: 'X')
      end
    end

    it 'rejects a warehouse from a different company', :aggregate_failures do
      order_item.warehouse = foreign_warehouse

      expect(order_item).not_to be_valid
      expect(order_item.errors[:base])
        .to include('warehouse must belong to the same company as the order')
    end
  end
end
