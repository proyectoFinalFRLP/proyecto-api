# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Shipments::ProcessTrackingEventJob, type: :job do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:service) do
    Service.create!(service_name: 'Andreani', type: 'courier',
                    uri: 'https://api.andreani.com/envios', http_method: 'POST')
  end
  let(:integration) do
    CompanyIntegration.create!(company: company, service: service,
                               credentials: { 'access_token' => 'SECRET-TOKEN' })
  end
  let(:log) do
    WebhookLog.create!(company: company, company_integration: integration,
                       payload: { 'numeroDeEnvio' => 'ABC123' }, status: 'pending')
  end
  let(:updater) { instance_double(Shipments::ProcessTrackingUpdate, call: true) }

  before { allow(Shipments::ProcessTrackingUpdate).to receive(:new).and_return(updater) }

  def run = described_class.new.perform(log.id, company.id)

  it 'delegates the ingestion to the tracking update PORO with the right log',
     :aggregate_failures do
    run

    expect(Shipments::ProcessTrackingUpdate).to have_received(:new).with(webhook_log: log)
    expect(updater).to have_received(:call)
  end

  it 'activates the tenant while it runs' do
    # El tenant se captura y se verifica después de correr: adentro del stub, el
    # fallo de la expectativa quedaría atrapado por el rescue del propio job y el
    # ejemplo pasaría en verde igual. Además `with_tenant` limpia Current al
    # terminar, así que después del run ya no se puede leer.
    captured_tenant = nil
    allow(updater).to receive(:call) { captured_tenant = Current.company_id }

    run

    expect(captured_tenant).to eq(company.id)
  end

  context 'when the webhook log no longer exists' do
    it 'finishes without raising nor delegating', :aggregate_failures do
      log.destroy!

      expect { run }.not_to raise_error
      expect(Shipments::ProcessTrackingUpdate).not_to have_received(:new)
    end
  end

  context 'when the PORO raises' do
    let(:updater) { instance_double(Shipments::ProcessTrackingUpdate) }

    before { allow(updater).to receive(:call).and_raise(StandardError, 'boom') }

    it 'does not propagate the exception' do
      expect { run }.not_to raise_error
    end

    it 'registers a failed event in the dead letter queue', :aggregate_failures do
      expect { run }.to change(FailedEvent, :count).by(1)

      event = FailedEvent.last
      expect(event.event_type).to eq('webhooks.tracking_ingestion')
      expect(event.direction).to eq('inbound')
      expect(event.payload).to eq('webhook_log_id' => log.id)
    end
  end
end
