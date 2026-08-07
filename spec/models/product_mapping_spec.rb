# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ProductMapping, type: :model do
  subject(:mapping) do
    described_class.new(product: product, company_integration: integration,
                        external_product_id: 'MLA-123')
  end

  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:product) { Product.create!(company: company, sku: 'SKU-001', name: 'Widget Alpha') }
  let(:integration) do
    service = Service.create!(service_name: 'Mercado Libre', type: 'ecommerce',
                              uri: 'https://api.mercadolibre.com', http_method: 'GET')
    CompanyIntegration.create!(company: company, service: service,
                               credentials: { access_token: 'test' })
  end

  let(:other_integration) do
    other_service = Service.create!(service_name: 'Shopify', type: 'ecommerce',
                                    uri: 'https://api.shopify.com', http_method: 'GET')
    CompanyIntegration.create!(company: company, service: other_service,
                               credentials: { token: 'xyz' })
  end

  let(:other_integration_other_co) do
    other_company = Company.create!(name: 'Other Corp', tax_id: '30-99999999-9')
    other_service = Service.create!(service_name: 'WooCommerce', type: 'ecommerce',
                                    uri: 'https://api.woo.com', http_method: 'GET')
    CompanyIntegration.create!(company: other_company, service: other_service,
                               credentials: { token: 'abc' })
  end

  it 'is valid with required attributes' do
    expect(mapping).to be_valid
  end

  it 'is invalid without a product' do
    mapping.product = nil
    expect(mapping).not_to be_valid
  end

  it 'is invalid without a company_integration' do
    mapping.company_integration = nil
    expect(mapping).not_to be_valid
  end

  it 'is invalid without external_product_id' do
    mapping.external_product_id = nil
    expect(mapping).not_to be_valid
  end

  it 'enforces uniqueness of product scoped to company_integration' do
    mapping.save!
    duplicate = described_class.new(product: product, company_integration: integration,
                                    external_product_id: 'MLA-456')
    expect(duplicate).not_to be_valid
  end

  it 'allows mapping the same product to different integrations' do
    mapping.save!
    other_mapping = described_class.new(product: product, company_integration: other_integration,
                                        external_product_id: 'shop-456')
    expect(other_mapping).to be_valid
  end

  describe 'external_price' do
    # La columna es decimal(10,2): sin validación, un valor mayor al tope
    # explota con ActiveRecord::RangeError (500) y un string no numérico se
    # castea a 0.0 sin avisar.
    it 'is valid when absent' do
      mapping.external_price = nil
      expect(mapping).to be_valid
    end

    it 'accepts the largest value the column can hold' do
      mapping.external_price = 99_999_999.99
      expect(mapping).to be_valid
    end

    it 'rejects a value above the column limit' do
      mapping.external_price = 100_000_000
      expect(mapping).not_to be_valid
    end

    it 'rejects a value that would round past the column limit' do
      mapping.external_price = 99_999_999.999
      expect(mapping).not_to be_valid
    end

    it 'rejects a non-numeric value instead of casting it to zero', :aggregate_failures do
      mapping.external_price = 'abc'
      expect(mapping).not_to be_valid
      expect(mapping.errors[:external_price]).to include('is not a number')
    end

    it 'rejects a negative value' do
      mapping.external_price = -50
      expect(mapping).not_to be_valid
    end
  end

  it 'rejects a product and integration from different companies', :aggregate_failures do
    mapping.company_integration = other_integration_other_co
    expect(mapping).not_to be_valid
    expect(mapping.errors[:base]).to include('product and integration must belong to the same company')
  end

  it 'is queryable within a tenant context' do
    Current.company_id = company.id
    expect { described_class.count }.not_to raise_error
  ensure
    Current.reset
  end

  it 'belongs to a product' do
    expect(described_class.reflect_on_association(:product).macro).to eq(:belongs_to)
  end

  it 'belongs to a company_integration' do
    expect(described_class.reflect_on_association(:company_integration).macro).to eq(:belongs_to)
  end
end
