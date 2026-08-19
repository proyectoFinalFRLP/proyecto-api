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
end
