# frozen_string_literal: true

require 'rails_helper'
require 'rake'

RSpec::Matchers.define_negated_matcher :not_have_enqueued_job, :have_enqueued_job

# Las tareas de lib/tasks/integrations.rake que tocan la publicación del stock
# (TESIS-177): `connect` prueba la conexión al terminar, y `resync` vuelve a
# publicar el stock de los productos vinculados (también en producción).
RSpec.describe 'integrations rake tasks' do # rubocop:disable RSpec/DescribeClass
  let(:company) { Company.create!(name: 'Norte', tax_id: '30-11111111-1', slug: 'norte') }
  let!(:shopify) do
    Service.create!(
      service_name: 'Shopify', type: 'ecommerce', http_method: 'POST',
      uri: 'https://:shop_domain/admin/api/2026-07/graphql.json', request_format: 'graphql',
      auth_strategy: 'oauth_client_credentials',
      auth_config: { 'token_url' => 'https://:shop_domain/admin/oauth/access_token',
                     'token_header' => 'X-Shopify-Access-Token', 'token_prefix' => '' },
      credential_fields: [{ 'key' => 'client_id', 'required' => true },
                          { 'key' => 'client_secret', 'required' => true }],
      setting_fields: [{ 'key' => 'shop_domain', 'required' => true },
                       { 'key' => 'location_id', 'label' => 'Ubicación de stock' }],
      request_mapper: { 'inventoryItemId' => 'inventory_item_id',
                        'locationId' => 'settings.location_id', 'quantity' => 'available_quantity' }
    )
  end
  let(:graphql_url) { 'https://norte.myshopify.com/admin/api/2026-07/graphql.json' }

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?('integrations:resync_stock')
  end

  def run(task, *args)
    Rake::Task[task].reenable
    Rake::Task[task].invoke(*args)
  end

  def connect_integration(settings)
    CompanyIntegration.create!(company: company, service: shopify,
                               settings: { 'shop_domain' => 'norte.myshopify.com' }.merge(settings),
                               credentials: { 'client_id' => 'CID', 'client_secret' => 'SECRET',
                                              'access_token' => 'TOKEN',
                                              'token_expires_at' => 1.hour.from_now.iso8601 })
  end

  def link(integration, sku)
    product = Product.create!(company: company, sku: sku, name: sku)
    ProductMapping.create!(product: product, company_integration: integration,
                           external_product_id: "V-#{sku}",
                           external_refs: { 'inventory_item_id' => "INV-#{sku}" })
  end

  after { Current.reset }

  describe 'integrations:shopify:resync' do
    it 'enqueues the stock of every linked product on Shopify', :aggregate_failures do
      integration = connect_integration('location_id' => 'gid://shopify/Location/1')
      %w[NOR-001 NOR-002].each { |sku| link(integration, sku) }

      expect { run('integrations:shopify:resync', 'norte') }
        .to output(/Shopify: 2 productos encolados/).to_stdout
        .and have_enqueued_job(Catalog::SyncStockToChannelsJob).exactly(2).times
    end

    it 'enqueues nothing and says why when the location is missing', :aggregate_failures do
      link(connect_integration({}), 'NOR-001')

      expect { run('integrations:shopify:resync', 'norte') }
        .to output(/no se encoló nada.*Ubicación de stock \(location_id\)/).to_stdout
        .and not_have_enqueued_job(Catalog::SyncStockToChannelsJob)
    end
  end

  describe 'integrations:resync_stock' do
    it 'resyncs every active channel of the company' do
      link(connect_integration('location_id' => 'gid://shopify/Location/1'), 'NOR-001')

      expect { run('integrations:resync_stock', 'norte') }
        .to have_enqueued_job(Catalog::SyncStockToChannelsJob).once
    end
  end

  describe 'integrations:shopify:connect' do
    before do
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new('development'))
      allow(DevEnv).to receive(:fetch) do |_prefix, _slug, name|
        { 'CLIENT_ID' => 'CID', 'CLIENT_SECRET' => 'SECRET', 'SHOP_DOMAIN' => 'norte.myshopify.com' }
          .fetch(name)
      end
      Service.create!(service_name: 'Shopify - Conexión', type: 'ecommerce', http_method: 'POST',
                      parent_service: shopify, operation: 'connection_test',
                      uri: shopify.uri, request_format: 'graphql', body_template: '{ shop { name } }',
                      response_mapper: { 'data.shop.name' => 'account_name',
                                         'data.locations.nodes.0.id' => 'location_id' })
      company
      stub_request(:post, 'https://norte.myshopify.com/admin/oauth/access_token')
        .to_return(status: 200, headers: { 'Content-Type' => 'application/json' },
                   body: { access_token: 'NEW', expires_in: 86_399 }.to_json)
      stub_request(:post, graphql_url).to_return(
        status: 200, headers: { 'Content-Type' => 'application/json' },
        body: { data: { shop: { name: 'Norte' },
                        locations: { nodes: [{ id: 'gid://shopify/Location/7' }] } } }.to_json
      )
    end

    it 'tests the connection right after connecting and fills the location', :aggregate_failures do
      expect { run('integrations:shopify:connect', 'norte') }
        .to output(/ok: true — Connected to Norte.*Lista para publicar el stock/m).to_stdout
      expect(CompanyIntegration.unscoped.last.settings['location_id']).to eq('gid://shopify/Location/7')
    end
  end
end
