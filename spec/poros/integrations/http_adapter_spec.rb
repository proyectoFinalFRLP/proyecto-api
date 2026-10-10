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

  # El verbo HTTP lo elige la plantilla del Service, que sólo valida presencia:
  # nada impide guardar un verbo que el adaptador no sabe construir. Sin este
  # ejemplo, el día que alguien agregue 'HEAD' a la plantilla el fallo aparece
  # como un NoMethodError adentro de un job, en vez del error del adaptador que
  # el motor de reintentos sabe manejar (TESIS-93).
  describe 'an http_method the adapter does not know' do
    before { service.update!(http_method: 'HEAD') }

    it 'raises AdapterExecutionError naming the verb', :aggregate_failures do
      expect { run_adapter }.to raise_error(Integrations::AdapterExecutionError) do |error|
        expect(error.message).to include('Andreani', 'HEAD')
      end
    end

    it 'does not reach the external API' do
      request = stub_request(:any, /andreani/)

      suppress(Integrations::AdapterExecutionError) { run_adapter }

      expect(request).not_to have_been_made
    end

    it 'carries the payload so the failure can be replayed', :aggregate_failures do
      expect { run_adapter }.to raise_error(Integrations::AdapterExecutionError) do |error|
        expect(error.payload).to eq({ customer_zip_code: '1900' })
      end
    end
  end

  describe 'credential keys used as header names' do
    def adapter_for(credentials)
      integration.update!(credentials: credentials)
      described_class.new(company_integration: integration,
                          payload: { customer_zip_code: '1900' },
                          uri_params: { order_id: 42 })
    end

    it 'rejects a credential key carrying CRLF (header injection)' do
      expect { adapter_for({ "X-Evil\r\nX-Injected" => 'boom' }).call }
        .to raise_error(Integrations::AdapterExecutionError, /invalid credential key/)
    end

    it 'rejects a credential key with a colon' do
      expect { adapter_for({ 'X-Bad: value' => 'boom' }).call }
        .to raise_error(Integrations::AdapterExecutionError, /invalid credential key/)
    end

    it 'rejects a blank credential key' do
      expect { adapter_for({ '' => 'boom' }).call }
        .to raise_error(Integrations::AdapterExecutionError, /invalid credential key/)
    end

    it 'does not reach the external API when a credential key is invalid' do
      stub = stub_request(:post, 'https://api.andreani.com/envios/42')
      suppress(Integrations::AdapterExecutionError) do
        adapter_for({ "X-Evil\r\nX-Injected" => 'boom' }).call
      end
      expect(stub).not_to have_been_requested
    end

    it 'accepts valid RFC 9110 token header names' do
      stub_request(:post, 'https://api.andreani.com/envios/42')
        .to_return(status: 200, body: {}.to_json)
      adapter_for({ 'X-Api-Key' => 'KEY-123' }).call
      expect(WebMock).to have_requested(:post, 'https://api.andreani.com/envios/42')
        .with(headers: { 'X-Api-Key' => 'KEY-123' })
    end
  end

  describe 'speaking with another template of the same provider' do
    let(:tracking_template) do
      Service.create!(service_name: 'Andreani - Seguimiento', type: 'courier', http_method: 'GET',
                      uri: 'https://api.andreani.com/tracking/:tracking_number')
    end

    before do
      stub_request(:get, 'https://api.andreani.com/tracking/AND-1')
        .to_return(status: 200, body: {}.to_json)
    end

    it 'uses the given template with the credentials of the integration' do
      described_class.new(company_integration: integration, service: tracking_template,
                          uri_params: { tracking_number: 'AND-1' }).fetch
      expect(WebMock).to have_requested(:get, 'https://api.andreani.com/tracking/AND-1')
        .with(headers: { 'Authorization' => 'Bearer SECRET-TOKEN' })
    end
  end

  describe 'timeouts' do
    let(:http) { Net::HTTP.new('api.andreani.com', 443) }

    before do
      allow(Net::HTTP).to receive(:new).and_return(http)
      stub_request(:post, 'https://api.andreani.com/envios/42')
        .to_return(status: 200, body: {}.to_json)
    end

    it 'uses the given timeout and keeps the default for the one not given' do
      described_class.new(company_integration: integration, uri_params: { order_id: 42 },
                          timeouts: { read: 3 }).call
      expect([http.open_timeout, http.read_timeout]).to eq([10, 3])
    end
  end

  describe '#fetch' do
    def fetch_raw
      described_class.new(company_integration: integration,
                          payload: { customer_zip_code: '1900' },
                          uri_params: { order_id: 42 }).fetch
    end

    it 'returns the JSON body untouched by the response mappers' do
      stub_request(:post, 'https://api.andreani.com/envios/42')
        .to_return(status: 200, body: { estado: 'Entregado', extra: 1 }.to_json)

      expect(fetch_raw).to eq('estado' => 'Entregado', 'extra' => 1)
    end

    it 'raises AdapterExecutionError on an HTTP error, like #call' do
      stub_request(:post, 'https://api.andreani.com/envios/42').to_return(status: 503)

      expect { fetch_raw }.to raise_error(Integrations::AdapterExecutionError, /HTTP 503/)
    end

    it 'raises AdapterExecutionError on a network failure, like #call' do
      stub_request(:post, 'https://api.andreani.com/envios/42').to_timeout

      expect { fetch_raw }.to raise_error(Integrations::AdapterExecutionError, /request failed/)
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

  # Proveedor real (TESIS-138): la plantilla se autentica con OAuth client
  # credentials, habla GraphQL y completa la URI con los settings de la cuenta.
  describe 'OAuth client credentials over GraphQL' do
    let(:shopify) do
      Service.create!(
        service_name: 'Shopify', type: 'ecommerce', http_method: 'POST',
        uri: 'https://:shop_domain/admin/api/2026-07/graphql.json',
        request_format: 'graphql', auth_strategy: 'oauth_client_credentials',
        auth_config: { 'token_url' => 'https://:shop_domain/admin/oauth/access_token',
                       'token_header' => 'X-Shopify-Access-Token', 'token_prefix' => '' },
        body_template: 'query Node($id: ID!) { node(id: $id) { id } }',
        request_mapper: { 'id' => 'node_gid' },
        response_mapper: { 'data.node.id' => 'node_id' },
        error_path: 'data.node.userErrors'
      )
    end
    let(:shop_integration) do
      CompanyIntegration.create!(
        company: company, service: shopify, settings: { 'shop_domain' => 'demo.myshopify.com' },
        credentials: { 'client_id' => 'CLIENT-ID', 'client_secret' => 'shpss_SECRET',
                       'access_token' => 'CACHED-TOKEN',
                       'token_expires_at' => 1.hour.from_now.iso8601 }
      )
    end

    def graphql_url = 'https://demo.myshopify.com/admin/api/2026-07/graphql.json'

    def token_url = 'https://demo.myshopify.com/admin/oauth/access_token'

    def run_graphql
      described_class.new(company_integration: shop_integration,
                          payload: { node_gid: 'gid://shopify/Node/1' }).call
    end

    def graphql_response(body)
      { status: 200, headers: { 'Content-Type' => 'application/json' }, body: body.to_json }
    end

    it 'sends the document with the mapped payload as variables to the URI of the account' do
      stub_request(:post, graphql_url).to_return(graphql_response(data: { node: { id: 'N1' } }))
      run_graphql
      expect(WebMock).to have_requested(:post, graphql_url).with(body: {
        query: shopify.body_template, variables: { id: 'gid://shopify/Node/1' }
      }.to_json)
    end

    it 'returns the mapped response' do
      stub_request(:post, graphql_url).to_return(graphql_response(data: { node: { id: 'N1' } }))
      expect(run_graphql).to eq('node_id' => 'N1')
    end

    it 'authenticates with the token in the declared header and never sends the secrets' do
      stub_request(:post, graphql_url).to_return(graphql_response(data: {}))
      run_graphql
      expect(WebMock).to(have_requested(:post, graphql_url).with { |request| token_only?(request) })
    end

    def token_only?(request)
      request.headers['X-Shopify-Access-Token'] == 'CACHED-TOKEN' &&
        request.headers['Authorization'].nil? &&
        request.headers.keys.none? { |key| key.downcase.include?('client') }
    end

    context 'when the provider rejects the cached token' do
      before do
        stub_request(:post, token_url)
          .to_return(graphql_response(access_token: 'NEW-TOKEN', expires_in: 86_399))
        stub_request(:post, graphql_url)
          .with(headers: { 'X-Shopify-Access-Token' => 'CACHED-TOKEN' }).to_return(status: 401)
        stub_request(:post, graphql_url).with(headers: { 'X-Shopify-Access-Token' => 'NEW-TOKEN' })
                                        .to_return(graphql_response(data: { node: { id: 'N1' } }))
      end

      it 'renews the token and retries with it' do
        expect(run_graphql).to eq('node_id' => 'N1')
      end

      it 'asks for a new token only once' do
        run_graphql
        expect(WebMock).to have_requested(:post, token_url).once
      end
    end

    it 'treats top-level GraphQL errors as a failure even with HTTP 200' do
      stub_request(:post, graphql_url)
        .to_return(graphql_response(errors: [{ message: 'Throttled' }]))

      expect { run_graphql }
        .to raise_error(Integrations::AdapterExecutionError, /returned errors: Throttled/)
    end

    it 'treats the errors listed in the declared error_path as a failure' do
      stub_request(:post, graphql_url).to_return(
        graphql_response(data: { node: { userErrors: [{ field: 'id', message: 'Not found' }] } })
      )

      expect { run_graphql }.to raise_error(Integrations::AdapterExecutionError, /Not found/)
    end

    it 'accepts an empty error list as a success' do
      stub_request(:post, graphql_url)
        .to_return(graphql_response(data: { node: { id: 'N1', userErrors: [] } }))

      expect(run_graphql).to eq('node_id' => 'N1')
    end
  end
end
