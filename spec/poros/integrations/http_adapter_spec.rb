# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Integrations::HttpAdapter, type: :poro do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:service) do
    Service.create!(service_name: 'Andreani', type: 'courier',
                    uri: 'https://api.andreani.com/envios/:order_id', http_method: 'POST',
                    request_mapper: { 'destino.codigoPostal' => 'customer_zip_code' },
                    request_value_mapper: { 'paid' => 'pagado' },
                    response_mapper: { 'bulto.0.numeroDeEnvio' => 'tracking_number',
                                       'estado' => 'status' },
                    response_value_mapper: { 'Entregado' => 'delivered' })
  end
  let(:integration) do
    CompanyIntegration.create!(company: company, service: service,
                               credentials: { 'access_token' => 'SECRET-TOKEN',
                                              'X-Api-Key' => 'KEY-123' })
  end

  def run_adapter
    described_class.new(company_integration: integration,
                        payload: { customer_zip_code: '1900' },
                        uri_params: { order_id: 42 }).call
  end

  describe 'happy path' do
    before do
      stub_request(:post, 'https://api.andreani.com/envios/42')
        .to_return(status: 200, headers: { 'Content-Type' => 'application/json' },
                   body: { bulto: [{ numeroDeEnvio: 'AND-99' }], estado: 'Entregado' }.to_json)
    end

    it 'returns the flattened internal response with translated values' do
      expect(run_adapter).to eq('tracking_number' => 'AND-99', 'status' => 'delivered')
    end

    it 'sends the payload mapped to the external structure' do
      run_adapter
      expect(WebMock).to have_requested(:post, 'https://api.andreani.com/envios/42')
        .with(body: { destino: { codigoPostal: '1900' } }.to_json)
    end

    it 'injects the decrypted credentials into the request headers' do
      run_adapter
      expect(WebMock).to have_requested(:post, 'https://api.andreani.com/envios/42')
        .with(headers: { 'Authorization' => 'Bearer SECRET-TOKEN', 'X-Api-Key' => 'KEY-123' })
    end
  end

  describe 'error handling' do
    it 'raises AdapterExecutionError on an HTTP 500', :aggregate_failures do
      stub_request(:post, 'https://api.andreani.com/envios/42').to_return(status: 500, body: 'boom')
      expect { run_adapter }.to raise_error(Integrations::AdapterExecutionError) do |error|
        expect(error.response_status).to eq(500)
        expect(error.payload).to eq(customer_zip_code: '1900')
      end
    end

    it 'raises AdapterExecutionError on an HTTP 404' do
      stub_request(:post, 'https://api.andreani.com/envios/42').to_return(status: 404)
      expect { run_adapter }.to raise_error(Integrations::AdapterExecutionError, /HTTP 404/)
    end

    it 'raises AdapterExecutionError when the request times out' do
      stub_request(:post, 'https://api.andreani.com/envios/42').to_timeout
      expect { run_adapter }.to raise_error(Integrations::AdapterExecutionError, /request failed/)
    end

    it 'raises AdapterExecutionError when the API is unreachable' do
      stub_request(:post, 'https://api.andreani.com/envios/42').to_raise(Errno::ECONNREFUSED)
      expect { run_adapter }.to raise_error(Integrations::AdapterExecutionError, /request failed/)
    end

    it 'raises AdapterExecutionError on a non-JSON response' do
      stub_request(:post, 'https://api.andreani.com/envios/42')
        .to_return(status: 200, body: '<html>not json</html>')
      expect { run_adapter }.to raise_error(Integrations::AdapterExecutionError, /non-JSON/)
    end
  end

  describe 'bodyless methods' do
    before do
      service.update!(http_method: 'GET', uri: 'https://api.andreani.com/envios/:order_id')
      stub_request(:get, 'https://api.andreani.com/envios/42')
        .to_return(status: 200, body: {}.to_json)
    end

    it 'sends GET requests without a body' do
      run_adapter
      expect(WebMock).to have_requested(:get, 'https://api.andreani.com/envios/42')
        .with(body: '')
    end
  end
end
