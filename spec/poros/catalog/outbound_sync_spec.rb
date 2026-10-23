# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Catalog::OutboundSync, type: :poro do
  subject(:sync) { described_class.new(product: product) }

  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:product) { Product.create!(company: company, sku: 'SKU-001', name: 'Celular') }
  let(:warehouse) do
    Warehouse.create!(company: company, name: 'Central', zip_code: '1900', address: 'Calle 1')
  end

  # Plantilla de canal: el id externo viaja en la URI y el request_mapper
  # traduce la clave interna available_quantity a la que espera la plataforma.
  def create_service(name, host)
    Service.create!(service_name: name, type: 'ecommerce', http_method: 'PUT',
                    uri: "https://#{host}/items/:external_id",
                    request_mapper: { 'stock.quantity' => 'available_quantity' })
  end

  def publish_on(name, host, external_id, token: 'TOKEN', active: true)
    integration = CompanyIntegration.create!(company: company, service: create_service(name, host),
                                             credentials: { 'access_token' => token },
                                             is_active: active)
    ProductMapping.create!(product: product, company_integration: integration,
                           external_product_id: external_id)
  end

  def stub_channel(host, external_id, status: 200)
    stub_request(:put, "https://#{host}/items/#{external_id}")
      .to_return(status: status, body: '{}')
  end

  before { Stock.create!(product: product, warehouse: warehouse, quantity: 10) }

  context 'when the product is not published on any channel' do
    it 'finishes without raising' do
      expect { sync.call }.not_to raise_error
    end

    it 'does not reach any external API' do
      sync.call
      expect(a_request(:any, //)).not_to have_been_made
    end
  end

  context 'when the product is published on one channel' do
    before do
      publish_on('Mercado Libre', 'api.ml.test', 'MLA-1')
      stub_channel('api.ml.test', 'MLA-1')
    end

    it 'calls the channel on the external id of the mapping' do
      sync.call
      expect(a_request(:put, 'https://api.ml.test/items/MLA-1')).to have_been_made.once
    end

    it 'sends the stock consolidated across every warehouse' do
      north = Warehouse.create!(company: company, name: 'North', zip_code: '1901', address: 'C 2')
      Stock.create!(product: product, warehouse: north, quantity: 5)
      sync.call
      expect(WebMock).to have_requested(:put, 'https://api.ml.test/items/MLA-1')
        .with(body: { stock: { quantity: 15 } }.to_json)
    end

    it 'authenticates with the credentials of the integration' do
      sync.call
      expect(WebMock).to have_requested(:put, 'https://api.ml.test/items/MLA-1')
        .with(headers: { 'Authorization' => 'Bearer TOKEN' })
    end
  end

  context 'when the product is published on three channels' do
    before do
      publish_on('Mercado Libre', 'api.ml.test', 'MLA-1', token: 'ML-TOKEN')
      publish_on('Tiendanube', 'api.tn.test', 'TN-2', token: 'TN-TOKEN')
      publish_on('Shopify', 'api.shop.test', 'SH-3', token: 'SH-TOKEN')
      stub_channel('api.ml.test', 'MLA-1')
      stub_channel('api.tn.test', 'TN-2')
      stub_channel('api.shop.test', 'SH-3')
    end

    it 'fires one request per channel', :aggregate_failures do
      sync.call
      expect(a_request(:put, 'https://api.ml.test/items/MLA-1')).to have_been_made.once
      expect(a_request(:put, 'https://api.tn.test/items/TN-2')).to have_been_made.once
      expect(a_request(:put, 'https://api.shop.test/items/SH-3')).to have_been_made.once
    end

    it 'uses the credentials of each channel', :aggregate_failures do
      sync.call
      expect(WebMock).to have_requested(:put, 'https://api.tn.test/items/TN-2')
        .with(headers: { 'Authorization' => 'Bearer TN-TOKEN' })
      expect(WebMock).to have_requested(:put, 'https://api.shop.test/items/SH-3')
        .with(headers: { 'Authorization' => 'Bearer SH-TOKEN' })
    end
  end

  context 'when one channel fails' do
    before do
      publish_on('Mercado Libre', 'api.ml.test', 'MLA-1')
      publish_on('Tiendanube', 'api.tn.test', 'TN-2')
      stub_channel('api.ml.test', 'MLA-1', status: 500)
      stub_channel('api.tn.test', 'TN-2')
    end

    it 'still propagates to the healthy channels' do
      suppress(Integrations::AdapterExecutionError) { sync.call }
      expect(a_request(:put, 'https://api.tn.test/items/TN-2')).to have_been_made.once
    end

    it 'raises so the worker marks the job as failed' do
      expect { sync.call }.to raise_error(Integrations::AdapterExecutionError, /1 of 2 channels/)
    end

    it 'names the failing channel in the error' do
      expect { sync.call }.to raise_error(Integrations::AdapterExecutionError, /Mercado Libre/)
    end

    it 'includes the response status of the failing channel in the error' do
      expect { sync.call }.to raise_error(Integrations::AdapterExecutionError, /status 500/)
    end

    # Un timeout no trae status HTTP: el mensaje tiene que nombrar el canal sin
    # inventar un código. Sólo estaba probado el fallo con respuesta (TESIS-93).
    it 'names a channel that failed without answering, and no status', :aggregate_failures do
      stub_request(:put, 'https://api.ml.test/items/MLA-1').to_timeout

      expect { sync.call }.to raise_error(Integrations::AdapterExecutionError) do |error|
        expect(error.message).to include('Mercado Libre')
        expect(error.message).not_to include('status')
      end
    end

    it 'still propagates to the healthy channel when the other times out' do
      stub_request(:put, 'https://api.ml.test/items/MLA-1').to_timeout

      suppress(Integrations::AdapterExecutionError) { sync.call }

      expect(a_request(:put, 'https://api.tn.test/items/TN-2')).to have_been_made.once
    end

    it 'aggregates every failing channel when they all fail' do
      stub_channel('api.tn.test', 'TN-2', status: 503)
      expect { sync.call }.to raise_error(Integrations::AdapterExecutionError, /2 of 2 channels/)
    end
  end

  context 'when a channel is deactivated' do
    before do
      publish_on('Mercado Libre', 'api.ml.test', 'MLA-1', active: false)
      publish_on('Tiendanube', 'api.tn.test', 'TN-2')
      stub_channel('api.tn.test', 'TN-2')
    end

    it 'does not send stock to the deactivated integration' do
      sync.call
      expect(a_request(:put, 'https://api.ml.test/items/MLA-1')).not_to have_been_made
    end

    it 'keeps syncing the active ones' do
      sync.call
      expect(a_request(:put, 'https://api.tn.test/items/TN-2')).to have_been_made.once
    end
  end

  # TESIS-138: sólo recibe stock una plantilla que sabe publicarlo.
  context 'when the channel template does not publish stock' do
    before do
      integration = CompanyIntegration.create!(
        company: company, credentials: { 'access_token' => 'TOKEN' },
        service: Service.create!(service_name: 'ML Orders', type: 'ecommerce', http_method: 'GET',
                                 uri: 'https://api.ml.test/orders')
      )
      ProductMapping.create!(product: product, company_integration: integration,
                             external_product_id: 'MLA-1')
    end

    it 'does not send it anything' do
      sync.call
      expect(a_request(:any, //)).not_to have_been_made
    end
  end

  context 'when the channel publishes stock with a child template and external refs' do
    before do
      parent = Service.create!(service_name: 'Shop', type: 'ecommerce', http_method: 'POST',
                               uri: 'https://shop.test/orders')
      Service.create!(service_name: 'Shop - Stock', type: 'ecommerce', http_method: 'POST',
                      uri: 'https://shop.test/inventory', parent_service: parent,
                      operation: 'stock',
                      request_mapper: { 'item' => 'inventory_item_id', 'qty' => 'available_quantity',
                                        'key' => 'idempotency_key' })
      integration = CompanyIntegration.create!(company: company, service: parent,
                                               credentials: { 'access_token' => 'TOKEN' })
      ProductMapping.create!(product: product, company_integration: integration,
                             external_product_id: '111', external_refs: { 'inventory_item_id' => 'INV-9' })
      stub_request(:post, 'https://shop.test/inventory').to_return(status: 200, body: '{}')
    end

    it 'sends the refs of the mapping and a fresh idempotency key to the stock template' do
      sync.call
      expect(a_request(:post, 'https://shop.test/inventory').with do |request|
        body = JSON.parse(request.body)
        body['item'] == 'INV-9' && body['qty'] == 10 && body['key'].to_s.match?(/\A\h{8}-/)
      end).to have_been_made.once
    end
  end

  context 'when scoped to one integration' do
    subject(:sync) { described_class.new(product: product, company_integration: shop.company_integration) }

    let(:shop) { publish_on('Shopify', 'shop.test', 'SH-1') }

    before do
      publish_on('Mercado Libre', 'api.ml.test', 'MLA-1')
      stub_channel('shop.test', 'SH-1')
    end

    it 'publishes only on that channel' do
      sync.call
      expect(a_request(:put, /api\.ml\.test/)).not_to have_been_made
    end
  end

  # TESIS-177: cada vínculo guarda cómo le fue en su último intento.
  describe 'the result of the last attempt' do
    let!(:mapping) { publish_on('Mercado Libre', 'api.ml.test', 'MLA-1') }

    it 'records a successful attempt without an error', :aggregate_failures do
      stub_channel('api.ml.test', 'MLA-1')
      mapping.update_columns(last_sync_error: 'old failure') # rubocop:disable Rails/SkipsModelValidations

      sync.call

      expect(mapping.reload.last_synced_at).to be_within(1.minute).of(Time.current)
      expect(mapping.last_sync_error).to be_nil
    end

    it 'records why the attempt failed', :aggregate_failures do
      stub_channel('api.ml.test', 'MLA-1', status: 500)

      suppress(Integrations::AdapterExecutionError) { sync.call }

      expect(mapping.reload.last_sync_error).to eq('Mercado Libre responded with HTTP 500 (status 500)')
      expect(mapping.last_synced_at).to be_present
    end

    it 'does not move updated_at: the attempt is not a change of the link' do
      stub_channel('api.ml.test', 'MLA-1')
      expect { sync.call }.not_to(change { mapping.reload.updated_at })
    end
  end

  # TESIS-177: en producción la integración de Shopify no tenía `location_id`,
  # el pedido salía con `locationId: null` y Shopify contestaba un error de
  # GraphQL que no decía qué faltaba. Ahora el pedido no sale.
  context 'when the stock template reads a setting the integration does not have' do
    let(:settings) { {} }
    let!(:mapping) do
      ProductMapping.create!(product: product, company_integration: shopify_integration,
                             external_product_id: '111',
                             external_refs: { 'inventory_item_id' => 'gid://shopify/InventoryItem/9' })
    end

    def shopify_integration
      shop = Service.create!(service_name: 'Shopify', type: 'ecommerce', http_method: 'POST',
                             uri: 'https://shop.test/graphql.json', request_format: 'graphql',
                             body_template: 'mutation SetStock { x }',
                             setting_fields: [{ 'key' => 'location_id', 'label' => 'Ubicación de stock' }],
                             request_mapper: { 'inventoryItemId' => 'inventory_item_id',
                                               'locationId' => 'settings.location_id',
                                               'quantity' => 'available_quantity' })
      CompanyIntegration.create!(company: company, service: shop, settings: settings,
                                 credentials: { 'access_token' => 'TOKEN' })
    end

    before { stub_request(:post, 'https://shop.test/graphql.json').to_return(status: 200, body: '{}') }

    it 'does not call the channel' do
      suppress(Catalog::ChannelNotReadyError) { sync.call }
      expect(a_request(:post, 'https://shop.test/graphql.json')).not_to have_been_made
    end

    it 'fails with a message that says what is missing' do
      expect { sync.call }.to raise_error(
        Catalog::ChannelNotReadyError,
        /Shopify cannot publish stock: the integration has no Ubicación de stock \(location_id\)/
      )
    end

    # Reintentar no completa un setting: no es un AdapterExecutionError, que
    # ApplicationJob reintenta.
    it 'is not a transient failure of the provider' do
      expect(Catalog::ChannelNotReadyError.ancestors).not_to include(Integrations::AdapterExecutionError)
    end

    it 'records the reason on the link' do
      suppress(Catalog::ChannelNotReadyError) { sync.call }
      expect(mapping.reload.last_sync_error).to include('Ubicación de stock (location_id)')
    end

    it 'still publishes on a healthy channel and retries as a provider failure if one fails' do
      publish_on('Mercado Libre', 'api.ml.test', 'MLA-1')
      stub_channel('api.ml.test', 'MLA-1', status: 500)

      expect { sync.call }.to raise_error(Integrations::AdapterExecutionError, /2 of 2 channels/)
    end

    context 'when the setting is there' do
      let(:settings) { { 'location_id' => 'gid://shopify/Location/7' } }

      it 'publishes with it' do
        sync.call
        expect(WebMock).to have_requested(:post, 'https://shop.test/graphql.json')
          .with(body: hash_including('variables' => hash_including(
            'locationId' => 'gid://shopify/Location/7', 'inventoryItemId' => 'gid://shopify/InventoryItem/9'
          )))
      end
    end

    # Un vínculo creado antes de la validación de ProductMapping puede no tener
    # las referencias: tampoco se manda a medias.
    context 'when the link has no inventory item' do
      let(:settings) { { 'location_id' => 'gid://shopify/Location/7' } }

      before { mapping.update_columns(external_refs: {}) } # rubocop:disable Rails/SkipsModelValidations

      it 'fails without calling the channel and says how to fix it', :aggregate_failures do
        expect { sync.call }.to raise_error(Catalog::ChannelNotReadyError,
                                            /no inventory_item_id\. Link it again/)
        expect(a_request(:post, 'https://shop.test/graphql.json')).not_to have_been_made
      end
    end
  end
end
