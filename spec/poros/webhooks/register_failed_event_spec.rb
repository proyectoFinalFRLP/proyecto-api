# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Webhooks::RegisterFailedEvent, type: :poro do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:service) do
    Service.create!(service_name: 'Andreani', type: 'courier',
                    uri: 'https://api.andreani.com/envios', http_method: 'POST')
  end
  let(:integration) do
    CompanyIntegration.create!(company: company, service: service,
                               credentials: { 'access_token' => 'SECRET-TOKEN' })
  end
  let(:error) do
    Integrations::AdapterExecutionError.new('Andreani responded with HTTP 503',
                                            payload: { zip: '1900' },
                                            response_status: 503, response_body: 'unavailable')
  end

  before { Current.company_id = company.id }

  def register(attributes = {})
    described_class.new(event_type: 'integrations.http_request',
                        payload: { 'payload' => { 'zip' => '1900' } },
                        company_integration: integration,
                        error: error,
                        **attributes).call
  end

  it 'persists the event as pending for the current tenant', :aggregate_failures do
    event = register

    expect(event).to have_attributes(status: 'pending', direction: 'outbound', attempts: 0,
                                     company_id: company.id, max_attempts: 5)
    expect(event.payload).to eq('payload' => { 'zip' => '1900' })
  end

  it 'schedules the first retry with the base backoff' do
    expect(register.next_retry_at).to be_between(59.seconds.from_now, 91.seconds.from_now)
  end

  it 'stores the diagnostic details of the adapter error', :aggregate_failures do
    event = register

    expect(event.last_error).to include('AdapterExecutionError', 'HTTP 503')
    expect(event.last_response_status).to eq(503)
    expect(event.last_response_body).to eq('unavailable')
  end

  it 'accepts a plain error without response details' do
    event = register(error: StandardError.new('boom'))

    expect(event).to have_attributes(last_error: 'StandardError: boom',
                                     last_response_status: nil, last_response_body: nil)
  end

  it 'truncates oversized error details' do
    event = register(error: StandardError.new('x' * 5_000))

    expect(event.last_error.length).to eq(FailedEvent::ERROR_LIMIT)
  end

  it 'registers inbound events too' do
    expect(register(direction: :inbound).direction).to eq('inbound')
  end

  it 'works without an integration nor an error' do
    event = described_class.new(event_type: 'orders.inbound_webhook').call

    expect(event).to have_attributes(company_id: company.id, company_integration_id: nil,
                                     last_error: nil, status: 'pending')
  end
end
