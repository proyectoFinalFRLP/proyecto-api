# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Integrations::RegisterWebhook, type: :poro do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:shopify) do
    Service.create!(service_name: 'Shopify', type: 'ecommerce', http_method: 'POST',
                    uri: 'https://:shop_domain/admin/api/2026-07/graphql.json',
                    request_format: 'graphql')
  end
  let(:integration) do
    CompanyIntegration.create!(company: company, service: shopify,
                               settings: { 'shop_domain' => 'demo.myshopify.com' },
                               credentials: { 'access_token' => 'TOKEN' })
  end

  def base_url = 'https://api.onestock.test'

  def graphql_url = 'https://demo.myshopify.com/admin/api/2026-07/graphql.json'

  def webhook_url = "#{base_url}/api/webhooks/integrations/#{integration.id}"

  def child(operation, body_template, response_mapper, error_path: nil)
    Service.create!(service_name: "Shopify - #{operation}", type: 'ecommerce', http_method: 'POST',
                    parent_service: shopify, operation: operation,
                    uri: 'https://:shop_domain/admin/api/2026-07/graphql.json',
                    request_format: 'graphql', body_template: body_template,
                    request_mapper: { 'uri' => 'webhook_url' }, response_mapper: response_mapper,
                    error_path: error_path)
  end

  def declare_subscription
    child('webhook_subscription', 'mutation Subscribe { webhookSubscriptionCreate }',
          { 'data.webhookSubscriptionCreate.webhookSubscription.id' => 'webhook_subscription_id' },
          error_path: 'data.webhookSubscriptionCreate.userErrors')
  end

  def declare_lookup
    child('webhook_lookup', 'query Webhook { webhookSubscriptions }',
          { 'data.webhookSubscriptions.nodes.0.id' => 'webhook_subscription_id' })
  end

  def graphql(data)
    { status: 200, headers: { 'Content-Type' => 'application/json' }, body: { data: data }.to_json }
  end

  # Con id, la suscripción quedó creada; sin él, el proveedor rechazó la
  # dirección (Shopify lo contesta con HTTP 200 y userErrors).
  def created(id)
    graphql(webhookSubscriptionCreate: { webhookSubscription: id && { id: id },
                                         userErrors: id ? [] : [{ field: ['uri'], message: 'Address is invalid' }] })
  end

  def found(*ids)
    graphql(webhookSubscriptions: { nodes: ids.map { |id| { id: id } } })
  end

  def stub_document(fragment, response)
    stub_request(:post, graphql_url).with { |request| request.body.include?(fragment) }
                                    .to_return(response)
  end

  def register(url = base_url)
    described_class.new(company_integration: integration, base_url: url).call
  end

  context 'when the template declares how to subscribe' do
    before { declare_subscription }

    let!(:create_request) do
      stub_document('webhookSubscriptionCreate', created('gid://shopify/WebhookSubscription/1'))
    end

    it 'reports the address it registered' do
      expect(register).to eq(ok: true, message: "Webhook registered: #{webhook_url}")
    end

    it 'sends the gateway of this integration as the address' do
      register
      expect(create_request.with { |r| JSON.parse(r.body)['variables'] == { 'uri' => webhook_url } })
        .to have_been_made
    end

    it 'reports the error of the provider without raising' do
      stub_document('webhookSubscriptionCreate', created(nil))
      expect(register).to include(ok: false, message: /Address is invalid/)
    end

    it 'does not call the provider without the public URL of the API', :aggregate_failures do
      expect(register(nil)).to eq(ok: false, message: 'PUBLIC_WEBHOOK_BASE_URL is not set')
      expect(create_request).not_to have_been_made
    end
  end

  context 'when the template can also look the subscription up' do
    before { declare_subscription && declare_lookup }

    let!(:create_request) do
      stub_document('webhookSubscriptionCreate', created('gid://shopify/WebhookSubscription/2'))
    end

    it 'does not subscribe twice to the same address', :aggregate_failures do
      stub_document('webhookSubscriptions', found('gid://shopify/WebhookSubscription/1'))
      expect(register).to eq(ok: true, message: "Webhook already registered: #{webhook_url}")
      expect(create_request).not_to have_been_made
    end

    it 'subscribes when the address is not registered yet', :aggregate_failures do
      stub_document('webhookSubscriptions', found)
      expect(register).to include(ok: true, message: /registered/)
      expect(create_request).to have_been_made
    end
  end

  context 'when the template does not declare a subscription' do
    it 'says so instead of calling the provider' do
      expect(register).to eq(ok: false, message: 'Shopify does not declare a subscription')
    end
  end

  context 'when the integration is a courier' do
    let(:shopify) do
      Service.create!(service_name: 'Courier', type: 'courier', http_method: 'POST',
                      uri: 'https://:shop_domain/webhooks', request_format: 'json')
    end

    it 'points the provider to the courier gateway' do
      expect(described_class.new(company_integration: integration, base_url: base_url).webhook_url)
        .to eq("#{base_url}/api/webhooks/couriers/#{integration.id}")
    end
  end
end
