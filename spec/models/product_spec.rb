# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Product, type: :model do
  subject(:product) do
    described_class.new(company: company, sku: 'SKU-001', name: 'Widget Alpha')
  end

  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }

  it 'is valid with required attributes' do
    expect(product).to be_valid
  end

  it 'defaults weight to 0.0' do
    product.save!
    expect(product.weight).to eq(0.0)
  end

  it 'is invalid without a company' do
    product.company = nil
    expect(product).not_to be_valid
  end

  describe 'category' do
    it 'is valid without one' do
      product.category = nil
      expect(product).to be_valid
    end

    it 'accepts every value of the vocabulary' do
      Product::CATEGORIES.each do |category|
        product.category = category
        expect(product).to be_valid, "expected #{category} to be valid"
      end
    end

    it 'rejects a value outside the vocabulary', :aggregate_failures do
      product.category = 'Groceries'
      expect(product).not_to be_valid
      expect(product.errors[:category]).to include('is not included in the list')
    end
  end

  describe '#primary_stock' do
    let(:central) do
      Warehouse.create!(company: company, name: 'Central', zip_code: '1900', address: 'Calle 1')
    end
    let(:north) do
      Warehouse.create!(company: company, name: 'North', zip_code: '1901', address: 'Calle 2')
    end

    before { product.save! }

    it 'is nil when the product has no stock rows' do
      expect(product.primary_stock).to be_nil
    end

    it 'returns the warehouse holding the most units' do
      Stock.create!(product: product, warehouse: central, quantity: 3)
      Stock.create!(product: product, warehouse: north, quantity: 9)

      expect(product.reload.primary_stock.warehouse_id).to eq(north.id)
    end

    it 'breaks ties by the lowest warehouse id' do
      Stock.create!(product: product, warehouse: north, quantity: 7)
      Stock.create!(product: product, warehouse: central, quantity: 7)

      expect(product.reload.primary_stock.warehouse_id).to eq([central.id, north.id].min)
    end

    it 'ignores rows holding zero units' do
      Stock.create!(product: product, warehouse: central, quantity: 0)
      Stock.create!(product: product, warehouse: north, quantity: 4)

      expect(product.reload.primary_stock.warehouse_id).to eq(north.id)
    end

    it 'is nil when every row holds zero units' do
      Stock.create!(product: product, warehouse: central, quantity: 0)

      expect(product.reload.primary_stock).to be_nil
    end
  end

  %i[sku name].each do |attribute|
    it "is invalid without #{attribute}" do
      product.public_send("#{attribute}=", nil)
      expect(product).not_to be_valid
    end
  end

  it 'enforces SKU uniqueness scoped to company' do
    product.save!
    duplicate = described_class.new(company: company, sku: 'SKU-001', name: 'Widget Beta')
    expect(duplicate).not_to be_valid
  end

  it 'allows the same SKU across different companies' do
    product.save!
    other_company = Company.create!(name: 'Other', tax_id: '30-12345678-9')
    other_product = described_class.new(company: other_company, sku: 'SKU-001', name: 'Widget Beta')
    expect(other_product).to be_valid
  end

  it 'validates weight is not negative' do
    product.weight = -1
    expect(product).not_to be_valid
  end

  it 'belongs to a company' do
    expect(described_class.reflect_on_association(:company).macro).to eq(:belongs_to)
  end

  it 'has many stocks' do
    expect(described_class.reflect_on_association(:stocks).macro).to eq(:has_many)
  end

  it 'has many product_mappings' do
    expect(described_class.reflect_on_association(:product_mappings).macro).to eq(:has_many)
  end
end
