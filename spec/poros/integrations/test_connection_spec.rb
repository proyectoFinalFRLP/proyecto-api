# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Integrations::TestConnection, type: :poro do
  let(:shopify) do
    Service.create!(
      service_name: 'Shopify', type: 'ecommerce', http_method: 'POST',
      uri: 'https://:shop_domain/admin/api/2026-07/graphql.json',
      request_format: 'graphql', auth_strategy: 'oauth_client_credentials',
      auth_config: { 'token_url' => 'https://:shop_domain/admin/oauth/access_token',
                     'token_header' => 'X-Shopify-Access-Token', 'token_prefix' => '' },
      setting_fields: [{ 'key' => 'shop_domain' }, { 'key' => 'location_id' }]
    )
  end
  let!(:connection_test) do
    Service.create!(
      service_name: 'Shopify - Conexión', type: 'ecommerce', http_method: 'POST',
      parent_service: shopify, operation: 'connection_test',
      uri: 'https://:shop_domain/admin/api/2026-07/graphql.json', request_format: 'graphql',
      body_template: '{ shop { name } locations(first: 5) { nodes { id name } } }',
      response_mapper: { 'data.shop.name' => 'account_name',
                         'data.locations.nodes.0.id' => 'location_id' }
    )
  end
  let(:settings) { { 'shop_domain' => 'demo.myshopify.com' } }
  let(:integration) do
    CompanyIntegration.create!(
      company: company, service: shopify, settings: settings,
      credentials: { 'client_id' => 'CLIENT-ID', 'client_secret' => 'shpss_SECRET',
                     'access_token' => 'CACHED-TOKEN',
                     'token_expires_at' => 1.hour.from_now.iso8601 }
    )
  end

  def graphql_url = 'https://demo.myshopify.com/admin/api/2026-07/graphql.json'

  def company
    @company ||= Company.create!(name: 'Acme', tax_id: '20-12345678-9')
  end

  def test_connection
    described_class.new(company_integration: integration).call
  end

  def shop_response
    { status: 200, headers: { 'Content-Type' => 'application/json' },
      body: { data: { shop: { name: 'Demo Store' },
                      locations: { nodes: [{ id: 'gid://shopify/Location/7', name: 'Main' }] } } }
        .to_json }
  end

  context 'when the provider answers' do
    before { stub_request(:post, graphql_url).to_return(shop_response) }

    it 'reports the account it connected to' do
      expect(test_connection).to eq(ok: true, message: 'Connected to Demo Store')
    end

    it 'runs the child template with the account of the parent integration' do
      test_connection
      expect(WebMock).to have_requested(:post, graphql_url)
        .with(headers: { 'X-Shopify-Access-Token' => 'CACHED-TOKEN' },
              body: hash_including('query' => connection_test.body_template))
    end

    it 'completes the declared settings the company did not load' do
      test_connection
      expect(integration.reload.settings)
        .to eq('shop_domain' => 'demo.myshopify.com', 'location_id' => 'gid://shopify/Location/7')
    end

    context 'when the company already chose a location' do
      let(:settings) do
        { 'shop_domain' => 'demo.myshopify.com', 'location_id' => 'gid://shopify/Location/9' }
      end

      it 'keeps it' do
        test_connection
        expect(integration.reload.settings['location_id']).to eq('gid://shopify/Location/9')
      end
    end
  end

  it 'returns the failure as a message instead of raising' do
    stub_request(:post, graphql_url).to_return(status: 403)

    expect(test_connection).to eq(ok: false, message: 'Shopify - Conexión responded with HTTP 403')
  end

  context 'when the template declares no connection test' do
    let(:bearer_service) do
      Service.create!(service_name: 'Tiendanube', type: 'ecommerce', http_method: 'PUT',
                      uri: 'https://api.tiendanube.com/v1/products')
    end
    let(:integration) do
      CompanyIntegration.create!(company: company, service: bearer_service,
                                 credentials: { 'access_token' => 'TOKEN' })
    end

    it 'says there is nothing to test' do
      expect(test_connection)
        .to eq(ok: false, message: 'Tiendanube does not declare a connection test')
    end
  end
end
