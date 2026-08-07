# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Webhooks::RetryFailedEvent, type: :poro do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:service) do
    Service.create!(service_name: 'Andreani', type: 'courier',
                    uri: 'https://api.andreani.com/envios/:order_id', http_method: 'POST',
                    response_mapper: { 'estado' => 'status' })
  end
  let(:integration) do
    CompanyIntegration.create!(company: company, service: service,
                               credentials: { 'access_token' => 'SECRET-TOKEN' })
  end
  let(:attempts) { 0 }
  let(:event) do
    FailedEvent.create!(company: company, company_integration: integration,
                        event_type: Webhooks::ReplayRegistry::HTTP_REQUEST,
                        payload: { 'payload' => { 'estado' => 'ok' },
                                   'uri_params' => { 'order_id' => 42 } },
                        status: :processing, attempts: attempts, max_attempts: 3)
  end

  before { Current.company_id = company.id }

  def url = 'https://api.andreani.com/envios/42'

  def retry_event = described_class.new(failed_event: event).call

  context 'when the replay succeeds' do
    before do
      stub_request(:post, url)
        .to_return(status: 200, headers: { 'Content-Type' => 'application/json' },
                   body: { estado: 'Entregado' }.to_json)
    end

    it 'marks the event as succeeded and stops the retry cycle', :aggregate_failures do
      retry_event
      expect(event.reload).to have_attributes(status: 'succeeded', attempts: 1,
                                              next_retry_at: nil, last_error: nil)
    end

    it 'replays the original request against the external service' do
      retry_event
      expect(WebMock).to have_requested(:post, url)
    end
  end

  context 'when the replay fails and attempts remain' do
    before { stub_request(:post, url).to_return(status: 503, body: 'unavailable') }

    it 'keeps the event pending and records the failure', :aggregate_failures do
      retry_event
      expect(event.reload).to have_attributes(status: 'pending', attempts: 1,
                                              last_response_status: 503)
    end

    it 'schedules the next attempt with exponential backoff' do
      retry_event
      expect(event.reload.next_retry_at).to be_between(119.seconds.from_now,
                                                       151.seconds.from_now)
    end

    it 'does not propagate the error to Active Job' do
      expect { retry_event }.not_to raise_error
    end
  end

  context 'when the last attempt fails' do
    let(:attempts) { 2 }

    before { stub_request(:post, url).to_return(status: 503, body: 'unavailable') }

    it 'moves the event to the dead letter queue', :aggregate_failures do
      retry_event
      expect(event.reload).to have_attributes(status: 'dead', attempts: 3, next_retry_at: nil)
      expect(event.last_error).to include('HTTP 503')
    end
  end

  context 'when the integration is no longer active' do
    before { integration.update!(is_active: false) }

    it 'records the failure without calling the external service', :aggregate_failures do
      retry_event
      expect(event.reload.status).to eq('pending')
      expect(event.last_error).to include('MissingIntegration')
    end
  end

  context 'when no replayer is registered for the event type' do
    let(:event) do
      FailedEvent.create!(company: company, event_type: 'orders.unknown', status: :processing,
                          max_attempts: 1)
    end

    it 'kills the event instead of retrying forever', :aggregate_failures do
      retry_event
      expect(event.reload.status).to eq('dead')
      expect(event.last_error).to include('UnknownEventType')
    end
  end
end
