# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Webhooks::Replayers::TrackingIngestion, type: :poro do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:integration) do
    service = Service.create!(service_name: 'Andreani', type: 'courier',
                              uri: 'https://api.andreani.com/envios', http_method: 'POST')
    CompanyIntegration.create!(company: company, service: service,
                               credentials: { 'access_token' => 'SECRET-TOKEN' })
  end
  let(:log) do
    WebhookLog.create!(company: company, company_integration: integration,
                       payload: { 'numeroDeEnvio' => 'ABC123' }, status: 'pending')
  end
  let(:event) do
    FailedEvent.create!(company: company, company_integration: integration,
                        event_type: Webhooks::ReplayRegistry::TRACKING_INGESTION,
                        direction: :inbound, payload: { 'webhook_log_id' => log.id },
                        status: :processing)
  end
  let(:updater) { instance_double(Shipments::ProcessTrackingUpdate, call: true) }

  before do
    Current.company_id = company.id
    allow(Shipments::ProcessTrackingUpdate).to receive(:new).and_return(updater)
  end

  def replay = described_class.new(failed_event: event).call

  it 'delegates the replay to the tracking update PORO with the log from the payload',
     :aggregate_failures do
    replay

    expect(Shipments::ProcessTrackingUpdate).to have_received(:new).with(webhook_log: log)
    expect(updater).to have_received(:call)
  end

  context 'when the webhook log no longer exists' do
    before { log.destroy! }

    it 'raises MissingWebhookLog instead of delegating', :aggregate_failures do
      expect { replay }.to raise_error(described_class::MissingWebhookLog)
      expect(Shipments::ProcessTrackingUpdate).not_to have_received(:new)
    end
  end

  it 'is registered under webhooks.tracking_ingestion' do
    expect(Webhooks::ReplayRegistry.fetch(Webhooks::ReplayRegistry::TRACKING_INGESTION))
      .to eq(described_class)
  end
end
