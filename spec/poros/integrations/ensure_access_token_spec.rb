# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Integrations::EnsureAccessToken, type: :poro do
  let(:service) do
    Service.create!(service_name: 'Shopify', type: 'ecommerce', http_method: 'POST',
                    uri: 'https://:shop_domain/admin/api/2026-07/graphql.json',
                    auth_strategy: 'oauth_client_credentials',
                    auth_config: { 'token_url' => 'https://:shop_domain/admin/oauth/access_token' })
  end
  let(:credentials) { { 'client_id' => 'CLIENT-ID', 'client_secret' => 'shpss_SECRET' } }
  let(:integration) do
    CompanyIntegration.create!(company: Company.create!(name: 'Acme', tax_id: '20-12345678-9'),
                               service: service, credentials: credentials,
                               settings: { 'shop_domain' => 'demo.myshopify.com' })
  end
  let!(:token_request) do
    stub_request(:post, token_url)
      .with(body: { 'grant_type' => 'client_credentials', 'client_id' => 'CLIENT-ID',
                    'client_secret' => 'shpss_SECRET' })
      .to_return(status: 200, headers: { 'Content-Type' => 'application/json' },
                 body: { access_token: 'NEW-TOKEN', scope: 'read_orders', expires_in: 86_399 }.to_json)
  end

  def token_url = 'https://demo.myshopify.com/admin/oauth/access_token'

  def ensure_token(force: false)
    described_class.new(company_integration: integration, force: force).call
  end

  def with_cached_token(token, expires_in:)
    integration.update!(credentials: credentials.merge(
      'access_token' => token, 'token_expires_at' => expires_in.from_now.iso8601
    ))
  end

  it 'asks the token endpoint of the account with the client credentials of the company' do
    expect(ensure_token).to eq('NEW-TOKEN')
  end

  it 'caches the token and its expiry in the encrypted credentials', :aggregate_failures do
    ensure_token
    stored = integration.reload.credentials
    expect(stored['access_token']).to eq('NEW-TOKEN')
    expect(Time.zone.parse(stored['token_expires_at'])).to be_within(1.minute).of(1.day.from_now)
  end

  it 'reuses the cached token while it is fresh', :aggregate_failures do
    with_cached_token('CACHED', expires_in: 1.hour)

    expect(ensure_token).to eq('CACHED')
    expect(token_request).not_to have_been_requested
  end

  it 'renews the token shortly before it expires, not after' do
    with_cached_token('ALMOST-EXPIRED', expires_in: 2.minutes)

    expect(ensure_token).to eq('NEW-TOKEN')
  end

  it 'renews a fresh token when forced (the provider rejected it)' do
    with_cached_token('REVOKED', expires_in: 1.hour)

    expect(ensure_token(force: true)).to eq('NEW-TOKEN')
  end

  # Dos workers ven el token vencido; el que espera el lock no pide otro si el
  # primero ya lo renovó.
  it 'does not ask again when another worker renewed it while waiting for the lock',
     :aggregate_failures do
    with_cached_token('EXPIRED', expires_in: -1.minute)
    stale_copy = CompanyIntegration.find(integration.id)
    with_cached_token('RENEWED-BY-OTHER', expires_in: 1.hour)

    expect(described_class.new(company_integration: stale_copy).call).to eq('RENEWED-BY-OTHER')
    expect(token_request).not_to have_been_requested
  end

  context 'when the company did not load its client secret' do
    let(:credentials) { { 'client_id' => 'CLIENT-ID' } }

    it 'fails with a clear message before calling the provider', :aggregate_failures do
      expect { ensure_token }
        .to raise_error(Integrations::AdapterExecutionError, /missing the credential client_secret/)
      expect(token_request).not_to have_been_requested
    end
  end

  context 'when the provider rejects the credentials' do
    before do
      stub_request(:post, token_url).to_return(
        status: 400, body: '<html><title>400 - Oauth error app_not_installed</title></html>'
      )
    end

    it 'says why without exposing the request or the response body', :aggregate_failures do
      expect { ensure_token }.to raise_error(Integrations::AdapterExecutionError) do |error|
        expect(error.message).to eq('Shopify token request responded with HTTP 400 (app_not_installed)')
        expect(error.response_body).to be_nil
      end
    end
  end
end
