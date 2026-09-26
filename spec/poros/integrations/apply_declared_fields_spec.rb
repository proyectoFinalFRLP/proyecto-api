# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Integrations::ApplyDeclaredFields, type: :poro do
  let(:service) do
    Service.create!(
      service_name: 'Shopify', type: 'ecommerce', http_method: 'POST',
      uri: 'https://:shop_domain/admin/api/2026-07/graphql.json',
      credential_fields: [{ 'key' => 'client_id', 'required' => true },
                          { 'key' => 'client_secret', 'required' => true }],
      setting_fields: [{ 'key' => 'shop_domain', 'required' => true,
                         'format' => '\A[a-z0-9][a-z0-9-]*\.myshopify\.com\z' },
                       { 'key' => 'location_id', 'required' => false }]
    )
  end
  let(:integration) { CompanyIntegration.new(service: service) }
  let(:complete) do
    { credentials: { 'client_id' => 'CID', 'client_secret' => 'shpss_S' },
      settings: { 'shop_domain' => 'demo.myshopify.com' } }
  end

  def apply(credentials: {}, settings: {})
    described_class.new(service: service, integration: integration,
                        credentials: credentials, settings: settings).call
  end

  def errors_for(**)
    apply(**)
  rescue Integrations::InvalidIntegrationError => e
    e.fields
  end

  it 'returns the declared credentials and settings when they are complete' do
    expect(apply(**complete))
      .to eq([{ 'client_id' => 'CID', 'client_secret' => 'shpss_S' },
              { 'shop_domain' => 'demo.myshopify.com' }])
  end

  it 'reports each missing required field with its scope' do
    expect(errors_for(credentials: { 'client_id' => 'CID' }))
      .to eq('credentials.client_secret' => ['required'], 'settings.shop_domain' => ['required'])
  end

  it 'reports a value that does not match the declared format' do
    expect(errors_for(**complete, settings: { 'shop_domain' => 'demo.com' }))
      .to eq('settings.shop_domain' => ['invalid_format'])
  end

  it 'refuses a field the template does not declare' do
    expect(errors_for(**complete, credentials: complete[:credentials].merge('pwd' => 'x')))
      .to eq('credentials.pwd' => ['unknown'])
  end

  context 'when the integration already has its credentials' do
    before do
      integration.credentials = { 'client_id' => 'CID', 'client_secret' => 'shpss_S',
                                  'access_token' => 'TOKEN', 'token_expires_at' => 'later' }
      integration.settings = { 'shop_domain' => 'demo.myshopify.com', 'location_id' => 'L1' }
    end

    it 'keeps a secret that arrives blank, and the token obtained with it' do
      credentials, = apply(credentials: { 'client_secret' => '' })
      expect(credentials).to include('client_secret' => 'shpss_S', 'access_token' => 'TOKEN')
    end

    it 'drops the cached token when a credential changes' do
      credentials, = apply(credentials: { 'client_secret' => 'shpss_NEW' })
      expect(credentials).to eq('client_id' => 'CID', 'client_secret' => 'shpss_NEW')
    end

    it 'clears a setting that arrives blank' do
      _, settings = apply(settings: { 'location_id' => '' })
      expect(settings).to eq('shop_domain' => 'demo.myshopify.com')
    end
  end
end
