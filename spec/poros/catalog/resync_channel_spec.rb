# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Catalog::ResyncChannel, type: :poro do
  subject(:resync) { described_class.new(company_integration: integration).call }

  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:shop) do
    Service.create!(service_name: 'Shopify', type: 'ecommerce', http_method: 'POST',
                    uri: 'https://shop.test/graphql',
                    setting_fields: [{ 'key' => 'location_id', 'label' => 'Ubicación de stock' }],
                    request_mapper: { 'item' => 'inventory_item_id', 'loc' => 'settings.location_id',
                                      'qty' => 'available_quantity' })
  end
  let(:settings) { { 'location_id' => 'gid://shopify/Location/1' } }
  let(:integration) do
    CompanyIntegration.create!(company: company, service: shop, settings: settings,
                               credentials: { 'access_token' => 'T' })
  end

  def link(sku, refs: { 'inventory_item_id' => "INV-#{sku}" })
    product = Product.create!(company: company, sku: sku, name: sku)
    ProductMapping.create!(product: product, company_integration: integration,
                           external_product_id: "V-#{sku}", external_refs: refs)
  end

  it 'enqueues one sync per linked product, scoped to the channel', :aggregate_failures do
    first = link('A')
    link('B')

    expect { resync }.to have_enqueued_job(Catalog::SyncStockToChannelsJob).exactly(2).times
    expect(Catalog::SyncStockToChannelsJob)
      .to have_been_enqueued.with(first.product_id, company.id, integration.id)
  end

  it 'reports how many it enqueued' do
    link('A')
    expect(resync.enqueued).to eq(1)
  end

  it 'skips a link without the refs and says why', :aggregate_failures do
    incomplete = link('A')
    incomplete.update_columns(external_refs: {}) # rubocop:disable Rails/SkipsModelValidations
    link('B')

    expect(resync.enqueued).to eq(1)
    expect(resync.skipped[incomplete.id]).to include('no inventory_item_id')
  end

  context 'when the integration is missing a setting the stock request needs' do
    let(:settings) { {} }

    it 'enqueues nothing and says what is missing', :aggregate_failures do
      link('A')

      expect do
        expect { resync }.to raise_error(Catalog::ChannelNotReadyError, /location_id/)
      end.not_to have_enqueued_job(Catalog::SyncStockToChannelsJob)
    end
  end

  it 'refuses an inactive integration' do
    integration.update!(is_active: false)
    expect { resync }.to raise_error(Catalog::ChannelNotReadyError, /inactive/)
  end

  it 'refuses a channel that does not publish stock' do
    shop.update!(request_mapper: {})
    expect { resync }.to raise_error(Catalog::ChannelNotReadyError, /does not publish stock/)
  end
end
