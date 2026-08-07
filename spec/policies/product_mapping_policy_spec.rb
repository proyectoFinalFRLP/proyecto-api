# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ProductMappingPolicy, type: :policy do
  subject(:policy) { described_class.new(user, mapping) }

  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:user) { User.create!(email: 'owner@example.com', password: 'password123', company: company) }
  let(:product) { Product.create!(company: company, sku: 'SKU-001', name: 'Widget Alpha') }
  let(:mapping) { mapping_for(product, 'Mercado Libre') }

  def mapping_for(mapped_product, service_name)
    service = Service.create!(service_name: service_name, type: 'ecommerce',
                              uri: 'https://api.example.com', http_method: 'GET')
    integration = CompanyIntegration.create!(company: mapped_product.company, service: service,
                                             credentials: { token: 'x' })
    ProductMapping.create!(product: mapped_product, company_integration: integration,
                           external_product_id: 'EXT-1')
  end

  def foreign_product
    @foreign_product ||= begin
      other_company = Company.create!(name: 'Other Corp', tax_id: '30-99999999-9')
      Product.create!(company: other_company, sku: 'SKU-002', name: 'Foreign')
    end
  end

  it 'allows listing the mappings to an authenticated user' do
    expect(policy).to be_index
  end

  it 'allows creating a mapping to an authenticated user' do
    expect(policy).to be_create
  end

  it 'allows destroying a mapping of the own company' do
    expect(policy).to be_destroy
  end

  context 'when the mapped product belongs to another company' do
    let(:mapping) { mapping_for(foreign_product, 'Shopify') }

    it 'denies destroying the mapping' do
      expect(policy).not_to be_destroy
    end
  end

  describe 'Scope' do
    it 'resolves only the mappings of the user company', :aggregate_failures do
      own = mapping_for(product, 'Mercado Libre')
      foreign = mapping_for(foreign_product, 'Shopify')

      resolved = ProductMappingPolicy::Scope.new(user, ProductMapping).resolve
      expect(resolved).to include(own)
      expect(resolved).not_to include(foreign)
    end
  end
end
