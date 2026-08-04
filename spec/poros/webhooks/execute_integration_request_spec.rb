# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Webhooks::ExecuteIntegrationRequest, type: :poro do
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

  before { Current.company_id = company.id }

  after { Current.reset }

  def url = 'https://api.andreani.com/envios/42'

  def execute
    described_class.new(company_integration: integration, payload: { 'estado' => 'ok' },
                        uri_params: { 'order_id' => 42 }).call
  end

  context 'when the external call succeeds' do
    before do
      stub_request(:post, url)
        .to_return(status: 200, headers: { 'Content-Type' => 'application/json' },
                   body: { estado: 'Entregado' }.to_json)
    end

    it 'returns the adapter response' do
      expect(execute).to eq('status' => 'Entregado')
    end

    it 'does not register anything in the dead letter queue' do
      expect { execute }.not_to change(FailedEvent, :count)
    end
  end

  context 'when the external call fails' do
    let(:event) { FailedEvent.last }

    before { stub_request(:post, url).to_return(status: 502, body: 'bad gateway') }

    it 'swallows the error so the business flow is not interrupted' do
      expect(execute).to be_nil
    end

    it 'registers one event in the dead letter queue' do
      expect { execute }.to change(FailedEvent, :count).by(1)
    end

    it 'registers it as a pending outbound http request', :aggregate_failures do
      execute
      expect(event).to have_attributes(status: 'pending', direction: 'outbound',
                                       event_type: 'integrations.http_request',
                                       company_integration_id: integration.id)
    end

    it 'keeps everything needed to replay the request' do
      execute
      expect(event.payload).to eq('payload' => { 'estado' => 'ok' },
                                  'uri_params' => { 'order_id' => 42 })
    end

    it 'stores the status of the failed response' do
      execute
      expect(event.last_response_status).to eq(502)
    end
  end

  context 'when the external service times out' do
    before { stub_request(:post, url).to_timeout }

    it 'registers the timeout as a retryable event', :aggregate_failures do
      expect { execute }.to change(FailedEvent, :count).by(1)
      expect(FailedEvent.last.last_error).to include('AdapterExecutionError')
    end
  end
end
