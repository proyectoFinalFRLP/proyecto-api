# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Shipments::PollTrackingJob, type: :job do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:integration) { courier_integration(company: company, name: 'Correo') }
  let(:poller) { instance_double(Shipments::PollTrackingStatus, call: []) }

  before { allow(Shipments::PollTrackingStatus).to receive(:new).and_return(poller) }

  def run(integration_id = integration.id) = described_class.new.perform(integration_id, [7, 8], company.id)

  it 'delegates to the polling PORO with the integration and the shipments', :aggregate_failures do
    run

    expect(Shipments::PollTrackingStatus).to have_received(:new)
      .with(company_integration: integration, shipment_ids: [7, 8])
    expect(poller).to have_received(:call)
  end

  it 'activates the tenant while it runs' do
    captured_tenant = nil
    allow(poller).to receive(:call) { captured_tenant = Current.company_id }

    run
    expect(captured_tenant).to eq(company.id)
  end

  it 'does not ask a courier whose integration was deactivated meanwhile' do
    integration.update!(is_active: false)
    run
    expect(Shipments::PollTrackingStatus).not_to have_received(:new)
  end

  it 'does nothing when the integration no longer exists' do
    run(0)
    expect(Shipments::PollTrackingStatus).not_to have_received(:new)
  end

  it 'runs in the low queue' do
    expect(described_class.new.queue_name).to eq('low')
  end

  it 'lets a single request per integration run at a time' do
    expect(described_class.concurrency_limit).to eq(1)
  end
end
