# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Webhooks::Replayers::OrderIngestion, type: :poro do
  subject(:replay) { described_class.new(failed_event: event) }

  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:integration) do
    service = Service.create!(service_name: 'Mercado Libre', type: 'ecommerce',
                              http_method: 'GET', uri: 'https://api.ml.test/orders')
    CompanyIntegration.create!(company: company, service: service)
  end
  let(:log) do
    WebhookLog.create!(company_id: company.id, company_integration: integration,
                       payload: { 'id' => 'ML-1' }, status: :failed)
  end
  let(:event) do
    FailedEvent.create!(company: company, company_integration: integration,
                        event_type: Webhooks::ReplayRegistry::ORDER_INGESTION,
                        direction: :inbound, payload: { 'webhook_log_id' => log.id })
  end

  before { Current.company_id = company.id }

  it 'is the replayer registered for the inbound ingestion events' do
    registered = Webhooks::ReplayRegistry.fetch(Webhooks::ReplayRegistry::ORDER_INGESTION)

    expect(registered).to eq(described_class)
  end

  it 'reprocesses the original webhook log' do
    processor = instance_double(Orders::ProcessWebhookOrder, call: true)
    allow(Orders::ProcessWebhookOrder).to receive(:new).with(webhook_log: log).and_return(processor)

    replay.call

    expect(processor).to have_received(:call)
  end

  # El replay corre dentro de RetryFailedEvent, que cuenta la excepción como un
  # intento fallido: sin el log no hay nada que reprocesar y el evento tiene que
  # agotar sus intentos en lugar de darse por exitoso.
  it 'fails when the webhook log no longer exists' do
    log.destroy!

    expect { replay.call }.to raise_error(described_class::MissingWebhookLog)
  end

  it 'does not reach a webhook log of another tenant' do
    event
    Current.company_id = Company.create!(name: 'Other', tax_id: '30-99999999-9').id

    expect { replay.call }.to raise_error(described_class::MissingWebhookLog)
  end
end
