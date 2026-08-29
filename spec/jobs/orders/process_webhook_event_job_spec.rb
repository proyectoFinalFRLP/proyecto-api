# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Orders::ProcessWebhookEventJob, type: :job do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:service) do
    Service.create!(service_name: 'Mercado Libre', type: 'ecommerce', http_method: 'GET',
                    uri: 'https://api.ml.test/orders')
  end
  let(:integration) { CompanyIntegration.create!(company: company, service: service) }
  let(:log) do
    WebhookLog.create!(company_id: company.id, company_integration: integration,
                       payload: { 'id' => 'ML-1' })
  end
  let(:processor) { instance_double(Orders::ProcessWebhookOrder, call: true) }

  before { allow(Orders::ProcessWebhookOrder).to receive(:new).and_return(processor) }

  def run(tenant = company.id) = described_class.new.perform(log.id, tenant)

  it 'runs on the realtime queue: an incoming sale is expected to land right away' do
    expect(described_class.new.queue_name).to eq('realtime')
  end

  it 'delegates the ingestion of the event to the PORO' do
    run

    expect(Orders::ProcessWebhookOrder).to have_received(:new).with(webhook_log: log)
  end

  it 'activates the tenant of the event before reading the database' do
    run

    expect(Current.company_id).to eq(company.id)
  end

  it 'ignores an event that belongs to another tenant' do
    other = Company.create!(name: 'Other', tax_id: '30-99999999-9')
    described_class.new.perform(log.id, other.id)

    expect(Orders::ProcessWebhookOrder).not_to have_received(:new)
  end

  it 'does not raise when the event no longer exists' do
    log.destroy!

    expect { run }.not_to raise_error
  end

  context 'when the ingestion fails' do
    before do
      allow(processor).to receive(:call)
        .and_raise(Orders::ProcessWebhookOrder::UnmappedProductError, 'MLA-1 is not mapped')
    end

    it 'derives the event to the dead letter queue instead of losing it' do
      expect { run }.to change(FailedEvent, :count).by(1)
    end

    it 'registers it as an inbound event of the ingestion type', :aggregate_failures do
      run

      expect(FailedEvent.last).to have_attributes(
        direction: 'inbound', event_type: Webhooks::ReplayRegistry::ORDER_INGESTION,
        company_integration_id: integration.id, status: 'pending'
      )
    end

    it 'keeps the id of the webhook log so the replay can rebuild the event' do
      run

      expect(FailedEvent.last.payload).to eq('webhook_log_id' => log.id)
    end

    it 'records the reason of the failure' do
      run

      expect(FailedEvent.last.last_error).to include('MLA-1 is not mapped')
    end

    # Si la excepción subiera, Active Job reintentaría por su cuenta el mismo
    # trabajo que la DLQ ya tiene agendado, con su propio backoff.
    it 'does not let the exception escape the job' do
      expect { run }.not_to raise_error
    end
  end
end
