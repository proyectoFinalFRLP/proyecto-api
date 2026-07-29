# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Stock, type: :model do
  subject(:stock) do
    described_class.new(product: product, warehouse: warehouse, quantity: 10)
  end

  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:product) { Product.create!(company: company, sku: 'SKU-001', name: 'Widget Alpha') }
  let(:warehouse) { Warehouse.create!(company: company, name: 'Central', zip_code: '1900', address: 'Calle 1') }

  it 'is valid with required attributes' do
    expect(stock).to be_valid
  end

  it 'defaults quantity to 0' do
    stock.quantity = nil
    expect(stock.quantity).to be_nil
  end

  it 'is invalid without a product' do
    stock.product = nil
    expect(stock).not_to be_valid
  end

  it 'is invalid without a warehouse' do
    stock.warehouse = nil
    expect(stock).not_to be_valid
  end

  it 'validates quantity is not negative' do
    stock.quantity = -1
    expect(stock).not_to be_valid
  end

  it 'enforces uniqueness of product scoped to warehouse' do
    stock.save!
    duplicate = described_class.new(product: product, warehouse: warehouse, quantity: 5)
    expect(duplicate).not_to be_valid
  end

  it 'allows same product in different warehouses' do
    stock.save!
    other_warehouse = Warehouse.create!(company: company, name: 'North', zip_code: '1901', address: 'Calle 2')
    other_stock = described_class.new(product: product, warehouse: other_warehouse, quantity: 5)
    expect(other_stock).to be_valid
  end

  it 'belongs to a product' do
    expect(described_class.reflect_on_association(:product).macro).to eq(:belongs_to)
  end

  it 'belongs to a warehouse' do
    expect(described_class.reflect_on_association(:warehouse).macro).to eq(:belongs_to)
  end
end
