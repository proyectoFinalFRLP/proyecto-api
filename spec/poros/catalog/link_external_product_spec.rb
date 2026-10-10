# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Catalog::LinkExternalProduct, type: :poro do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:product) { Product.create!(company: company, sku: 'NOR-001', name: 'Celular') }
  let(:shop) do
    Service.create!(service_name: 'Shop', type: 'ecommerce', http_method: 'POST',
                    uri: 'https://shop.test/graphql')
  end
  let(:integration) do
    CompanyIntegration.create!(company: company, service: shop,
                               credentials: { 'access_token' => 'TOKEN' })
  end

  def add_child(operation, response_mapper)
    Service.create!(service_name: "Shop - #{operation}", type: 'ecommerce', http_method: 'POST',
                    uri: "https://shop.test/#{operation}", parent_service: shop,
                    operation: operation, request_mapper: { 'id' => 'external_id', 'q' => 'sku' },
                    response_mapper: response_mapper)
  end

  def stub_child(operation, body)
    stub_request(:post, "https://shop.test/#{operation}")
      .to_return(status: 200, headers: { 'Content-Type' => 'application/json' }, body: body.to_json)
  end

  def link(external_product_id: nil)
    described_class.new(product: product, company_integration: integration,
                        external_product_id: external_product_id).call
  end

  context 'when the provider cannot look products up' do
    it 'links the external id as it came' do
      expect(link(external_product_id: 'MLA-1').mapping.external_product_id).to eq('MLA-1')
    end

    it 'pushes the stock of the product only to the channel it was linked to' do
      expect { link(external_product_id: 'MLA-1') }
        .to have_enqueued_job(Catalog::SyncStockToChannelsJob)
        .with(product.id, company.id, integration.id)
    end

    it 'requires the external id, because it cannot search by SKU' do
      expect { link }.to raise_error(Catalog::ExternalProductNotFoundError,
                                     'external_product_id is required')
    end
  end

  context 'when the provider looks a variant up by id' do
    before do
      add_child('product_lookup', { 'variant.sku' => 'external_sku',
                                    'variant.inventory' => 'inventory_item_id' })
    end

    it 'stores the channel identifiers it needs to publish the stock' do
      stub_child('product_lookup', variant: { sku: 'NOR-001', inventory: 'gid://inv/9' })

      expect(link(external_product_id: '111').mapping.external_refs)
        .to eq('inventory_item_id' => 'gid://inv/9')
    end

    it 'links it but warns when the SKU of the channel is another one' do
      stub_child('product_lookup', variant: { sku: 'OTRO-9', inventory: 'gid://inv/9' })

      expect(link(external_product_id: '111').warnings)
        .to eq(['The Shop SKU is OTRO-9, the product SKU is NOR-001'])
    end

    it 'refuses a variant that does not exist in the store', :aggregate_failures do
      stub_child('product_lookup', variant: nil)

      expect { link(external_product_id: '999') }
        .to raise_error(Catalog::ExternalProductNotFoundError, '999 does not exist in Shop')
      expect(ProductMapping.count).to eq(0)
    end
  end

  context 'when the provider searches variants by SKU' do
    before do
      add_child('product_search', { 'nodes.0.id' => 'external_product_id',
                                    'nodes.0.sku' => 'external_sku',
                                    'nodes.0.inventory' => 'inventory_item_id',
                                    'nodes.1.id' => 'ambiguous_match' })
    end

    it 'links the only variant with the SKU of the product', :aggregate_failures do
      stub_child('product_search', nodes: [{ id: '111', sku: 'nor-001', inventory: 'gid://inv/9' }])
      mapping = link.mapping

      expect(mapping.external_product_id).to eq('111')
      expect(mapping.external_refs).to eq('inventory_item_id' => 'gid://inv/9')
    end

    it 'refuses a result whose SKU is only similar' do
      stub_child('product_search', nodes: [{ id: '111', sku: 'NOR-0010' }])

      expect { link }.to raise_error(Catalog::ExternalProductNotFoundError, /has the SKU NOR-001/)
    end

    it 'refuses to choose between two variants with the same SKU' do
      stub_child('product_search', nodes: [{ id: '111', sku: 'NOR-001' }, { id: '222', sku: 'NOR-001' }])

      expect { link }.to raise_error(Catalog::ExternalProductNotFoundError, /more than one/)
    end
  end
end
