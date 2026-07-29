# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Webhooks gateway', type: :request do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:service) do
    Service.create!(service_name: 'Mercado Libre', type: 'ecommerce',
                    uri: 'https://api.mercadolibre.com', http_method: 'GET')
  end
  let(:integration) { CompanyIntegration.create!(company: company, service: service) }
  let(:payload) { { topic: 'orders_v2', resource: '/orders/123', received: { qty: 2 } } }

  def post_webhook(id = integration.id, body = payload, headers = {})
    post "/api/webhooks/integrations/#{id}", params: body, headers: headers, as: :json
  end

  describe 'POST /api/webhooks/integrations/:company_integration_id' do
    it 'accepts the request without a JWT' do
      post_webhook
      expect(response).to have_http_status(:accepted)
    end

    it 'persists the event' do
      expect { post_webhook }.to change(WebhookLog.unscoped, :count).by(1)
    end

    it 'stores the payload exactly as sent, including nested structures' do
      post_webhook
      expect(WebhookLog.unscoped.last.payload).to eq(
        'topic' => 'orders_v2', 'resource' => '/orders/123', 'received' => { 'qty' => 2 }
      )
    end

    it 'links the log to the integration and its tenant', :aggregate_failures do
      post_webhook
      log = WebhookLog.unscoped.last
      expect(log.company_integration_id).to eq(integration.id)
      expect(log.company_id).to eq(company.id)
    end

    it 'starts in pending status with no error message', :aggregate_failures do
      post_webhook
      log = WebhookLog.unscoped.last
      expect(log.status).to eq('pending')
      expect(log.error_message).to be_nil
    end

    it 'stores the incoming HTTP headers' do
      post_webhook(integration.id, payload, { 'X-Signature' => 'abc123' })
      expect(WebhookLog.unscoped.last.headers['HTTP_X_SIGNATURE']).to eq('abc123')
    end

    it 'does not store sensitive headers' do
      post_webhook(integration.id, payload, { 'Authorization' => 'Bearer secret-token' })
      expect(WebhookLog.unscoped.last.headers).not_to have_key('HTTP_AUTHORIZATION')
    end

    it 'returns an empty body (fire and forget)' do
      post_webhook
      expect(response.body).to be_empty
    end

    context 'when the body is not valid JSON' do
      def post_broken_body
        post "/api/webhooks/integrations/#{integration.id}",
             params: '{roto', headers: { 'CONTENT_TYPE' => 'application/json' }
      end

      it 'still accepts the event instead of rejecting the provider' do
        post_broken_body
        expect(response).to have_http_status(:accepted)
      end

      it 'keeps the raw body so the event can be replayed later' do
        post_broken_body
        expect(WebhookLog.unscoped.last.payload).to eq('raw' => '{roto')
      end
    end

    context 'when the integration does not exist' do
      it 'returns 404' do
        post_webhook(999_999)
        expect(response).to have_http_status(:not_found)
      end

      it 'does not persist anything' do
        expect { post_webhook(999_999) }.not_to change(WebhookLog.unscoped, :count)
      end
    end

    context 'when another tenant owns the integration' do
      let(:other_integration) do
        other = Company.create!(name: 'Otra', tax_id: '30-99999999-9')
        CompanyIntegration.create!(company: other, service: service)
      end

      it 'logs the event under the owning tenant, not the caller' do
        post_webhook(other_integration.id)
        expect(WebhookLog.unscoped.last.company_id).to eq(other_integration.company_id)
      end
    end
  end
end
