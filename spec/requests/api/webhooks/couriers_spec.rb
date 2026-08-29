# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Webhooks couriers gateway', type: :request do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:courier_service) do
    Service.create!(service_name: 'Correo Argentino', type: 'courier',
                    uri: 'https://api.correoargentino.com.ar', http_method: 'POST')
  end
  let(:ecommerce_service) do
    Service.create!(service_name: 'Mercado Libre', type: 'ecommerce',
                    uri: 'https://api.mercadolibre.com', http_method: 'GET')
  end
  let(:integration) { CompanyIntegration.create!(company: company, service: courier_service) }
  let(:payload) { { trackingNumber: 'TRK-1', estado: 'Entregado' } }

  def post_webhook(id = integration.id, body = payload, headers = {})
    post "/api/webhooks/couriers/#{id}", params: body, headers: headers, as: :json
  end

  describe 'POST /api/webhooks/couriers/:company_integration_id' do
    it 'accepts the request without a JWT and returns an empty body', :aggregate_failures do
      post_webhook
      expect(response).to have_http_status(:accepted)
      expect(response.body).to be_empty
    end

    it 'persists the event with its payload and headers under the integration tenant',
       :aggregate_failures do
      post_webhook(integration.id, payload, { 'X-Signature' => 'abc123' })
      log = WebhookLog.unscoped.last
      expect(log.company_id).to eq(integration.company_id)
      expect(log.payload).to eq('trackingNumber' => 'TRK-1', 'estado' => 'Entregado')
      expect(log.headers['HTTP_X_SIGNATURE']).to eq('abc123')
    end

    it 'does not store sensitive headers' do
      post_webhook(integration.id, payload, { 'Authorization' => 'Bearer secret-token' })
      expect(WebhookLog.unscoped.last.headers).not_to have_key('HTTP_AUTHORIZATION')
    end

    context 'when the integration is a courier' do
      it 'enqueues the tracking event job with the log id and its tenant' do
        # El id del WebhookLog no se conoce hasta que el POST corre, así que se
        # valida el tipo en vez del valor exacto; el company_id sí es conocido
        # de antemano porque sale de la integración.
        expect { post_webhook }
          .to have_enqueued_job(Shipments::ProcessTrackingEventJob)
          .with(kind_of(Integer), integration.company_id)
      end
    end

    context 'when the integration is not a courier (e-commerce)' do
      let(:integration) { CompanyIntegration.create!(company: company, service: ecommerce_service) }

      it 'does not enqueue any job' do
        expect { post_webhook }.not_to have_enqueued_job(Shipments::ProcessTrackingEventJob)
      end

      it 'still persists the event and returns 202', :aggregate_failures do
        expect { post_webhook }.to change(WebhookLog.unscoped, :count).by(1)
        expect(response).to have_http_status(:accepted)
      end
    end

    context 'when the integration does not exist' do
      it 'returns 404 and persists nothing', :aggregate_failures do
        expect { post_webhook(999_999) }.not_to change(WebhookLog.unscoped, :count)
        expect(response).to have_http_status(:not_found)
      end
    end

    context 'when the body is not valid JSON' do
      it 'still accepts the event and keeps the raw body', :aggregate_failures do
        post "/api/webhooks/couriers/#{integration.id}",
             params: '{roto', headers: { 'CONTENT_TYPE' => 'application/json' }
        expect(response).to have_http_status(:accepted)
        expect(WebhookLog.unscoped.last.payload).to eq('raw' => '{roto')
      end
    end
  end
end
