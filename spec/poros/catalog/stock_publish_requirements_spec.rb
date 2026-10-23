# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Catalog::StockPublishRequirements, type: :poro do
  subject(:requirements) { described_class.new(parent) }

  let(:parent) do
    Service.create!(service_name: 'Shopify', type: 'ecommerce', http_method: 'POST',
                    uri: 'https://shop.test/graphql', request_mapper: mapper,
                    setting_fields: [{ 'key' => 'shop_domain', 'label' => 'Dominio' },
                                     { 'key' => 'location_id', 'label' => 'Ubicación de stock' }])
  end
  # El request_mapper de la plantilla de Shopify de los seeds.
  let(:mapper) do
    { 'inventoryItemId' => 'inventory_item_id', 'locationId' => 'settings.location_id',
      'quantity' => 'available_quantity', 'idempotencyKey' => 'idempotency_key' }
  end

  it 'reads the settings the stock request needs from the template' do
    expect(requirements.setting_keys).to eq(['location_id'])
  end

  it 'reads the refs the link has to carry, leaving out what the sync sends' do
    expect(requirements.ref_keys).to eq(['inventory_item_id'])
  end

  it 'names a missing setting with the label the template declares' do
    expect(requirements.missing_settings('shop_domain' => 'x.myshopify.com'))
      .to eq([{ 'key' => 'location_id', 'label' => 'Ubicación de stock' }])
  end

  it 'treats a blank setting as missing' do
    expect(requirements.missing_settings('location_id' => ' ').size).to eq(1)
  end

  it 'has nothing to say when the setting is there' do
    expect(requirements.setting_problem('location_id' => 'gid://shopify/Location/1')).to be_nil
  end

  it 'explains how to fix a missing setting' do
    expect(requirements.setting_problem({}))
      .to eq('Shopify cannot publish stock: the integration has no Ubicación de stock ' \
             '(location_id) configured. Run «Test connection» or load it with «Configure connection»')
  end

  it 'explains how to fix missing refs' do
    expect(requirements.refs_problem({})).to include('no inventory_item_id. Link it again')
  end

  context 'with composed values' do
    let(:mapper) do
      { 'id' => 'gid://shopify/ProductVariant/{{external_id}}',
        'location' => '{{settings.location_id}}', 'note' => '{{settings.note|default:-}}',
        'item' => 'gid://x/{{inventory_item_id}}', 'when' => '{{today|date:%Y}}',
        'user' => 'credentials.client_id', 'flag' => 'literal:true',
        'qty' => 'available_quantity' }
    end

    it 'counts the variables without a default', :aggregate_failures do
      expect(requirements.setting_keys).to eq(['location_id'])
      expect(requirements.ref_keys).to eq(['inventory_item_id'])
    end
  end

  context 'when the stock is published by a child template' do
    let(:mapper) { {} }

    before do
      Service.create!(service_name: 'Shopify - Stock', type: 'ecommerce', http_method: 'POST',
                      uri: 'https://shop.test/graphql', parent_service: parent, operation: 'stock',
                      request_mapper: { 'loc' => 'settings.location_id', 'q' => 'available_quantity' })
    end

    it 'reads the child' do
      expect(requirements.setting_keys).to eq(['location_id'])
    end
  end

  context 'when the template does not publish stock' do
    let(:mapper) { { 'street' => 'customer_address' } }

    it 'requires nothing', :aggregate_failures do
      expect(requirements.publishes_stock?).to be(false)
      expect(requirements.missing_settings({})).to eq([])
      expect(requirements.missing_refs({})).to eq([])
    end
  end
end
