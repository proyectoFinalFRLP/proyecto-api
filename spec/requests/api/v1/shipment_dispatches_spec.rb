# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Shipment dispatch API', type: :request do
  let(:company) { Company.create!(name: 'Tenant A', tax_id: '30-11111111-1') }
  let(:user) { User.create!(email: 'a@example.com', password: 'password123', company: company) }
  let(:headers) { auth_headers(user) }
  let(:shipment) { Shipment.create!(company: company, order: order, status: 'pending') }
  let(:integration) { dispatch_integration(company) }

  # Métodos y no `let` para no pasarse del límite de helpers memoizados del
  # grupo: son datos de contexto que ningún ejemplo redefine.
  def warehouse
    @warehouse ||= Warehouse.create!(company: company, name: 'Central', zip_code: '1900',
                                     address: 'Calle 1')
  end

  def order
    @order ||= Order.create!(company: company, customer_name: 'Ana', customer_zip_code: '5000',
                             customer_address: 'Av. Siempreviva 742')
  end

  def auth_headers(user)
    post '/api/v1/auth/login', params: { email: user.email, password: 'password123' },
                               headers: { 'X-Tenant-Slug' => user.company.slug }
    { 'Authorization' => "Bearer #{response.parsed_body['token']}" }
  end

  def dispatch_integration(owner, name: 'Andreani')
    service = courier_service(name, uri: 'https://andreani.test/ordenes',
                                    request_mapper: { 'destino.cp' => 'destination_zip_code' },
                                    response_mapper: { 'numero' => 'tracking_number',
                                                       'etiqueta' => 'shipping_label_url' })
    CompanyIntegration.create!(company: owner, service: service,
                               credentials: { 'access_token' => 'T' })
  end

  def stub_courier(status: 200, body: { numero: 'AND-999', etiqueta: 'https://l.test/1.pdf' })
    stub_request(:post, 'https://andreani.test/ordenes')
      .to_return(status: status, body: body.to_json,
                 headers: { 'Content-Type' => 'application/json' })
  end

  def dispatch_shipment(id: shipment.id, integration_id: integration.id,
                        warehouse_id: warehouse.id, auth: headers, **extra)
    post "/api/v1/shipments/#{id}/dispatch",
         params: { dispatch: { company_integration_id: integration_id,
                               origin_warehouse_id: warehouse_id, **extra } },
         headers: auth, as: :json
  end

  it 'returns 401 without a token' do
    post "/api/v1/shipments/#{shipment.id}/dispatch", as: :json

    expect(response).to have_http_status(:unauthorized)
  end

  describe 'a successful dispatch' do
    before do
      stub_courier
      dispatch_shipment
    end

    it 'returns 200' do
      expect(response).to have_http_status(:ok)
    end

    # Criterio de la card: se obtiene y guarda el tracking y el enlace al PDF.
    it 'returns the shipment with its tracking and label', :aggregate_failures do
      expect(response.parsed_body['tracking_number']).to eq('AND-999')
      expect(response.parsed_body['shipping_label_url']).to eq('https://l.test/1.pdf')
      expect(response.parsed_body['status']).to eq('ready_to_ship')
    end

    it 'returns the courier that carries it' do
      expect(response.parsed_body['courier']).to include('id' => integration.id,
                                                         'name' => 'Andreani')
    end

    # Criterio de la card: queda el primer registro histórico de la bitácora.
    it 'returns the first event of the log' do
      expect(response.parsed_body['events'].pluck('external_status'))
        .to eq(['Etiqueta generada'])
    end
  end

  # El costo de la opción que el operador confirmó al cotizar (TESIS-131). Sin
  # esto el detalle de la orden mostraba el envío «a cotizar» para siempre.
  describe 'the confirmed shipping cost' do
    before { stub_courier }

    it 'is kept on the shipment and read back from it', :aggregate_failures do
      dispatch_shipment(shipping_cost: 2500.5)
      expect(response.parsed_body['shipping_cost']).to eq(2500.5)

      get "/api/v1/shipments/#{shipment.id}", headers: headers
      expect(response.parsed_body['shipping_cost']).to eq(2500.5)
    end

    it 'leaves the cost as it was when the dispatch does not bring one' do
      shipment.update!(shipping_cost: 900)
      dispatch_shipment

      expect(shipment.reload.shipping_cost).to eq(900)
    end

    # Se valida antes de pedir la etiqueta: el courier la cobra, y gastarla en
    # un despacho que después no se puede guardar es plata tirada.
    { 'negative' => -1, 'not a number' => 'mucho' }.each do |label, cost|
      it "answers 400 for a cost that is #{label}, without asking the courier", :aggregate_failures do
        dispatch_shipment(shipping_cost: cost)

        expect(response).to have_http_status(:bad_request)
        expect(WebMock).not_to have_requested(:post, 'https://andreani.test/ordenes')
      end
    end
  end

  # Criterio de la card: no se puede despachar dos veces el mismo paquete.
  it 'returns 409 when the shipment was already dispatched' do
    stub_courier
    dispatch_shipment
    dispatch_shipment

    expect(response).to have_http_status(:conflict)
  end

  describe 'when the courier rejects the request' do
    before do
      stub_courier(status: 422, body: { error: 'codigo postal invalido' })
      dispatch_shipment
    end

    # Un rechazo del courier es un dato que el usuario puede corregir.
    it 'returns 422' do
      expect(response).to have_http_status(:unprocessable_content)
    end

    # Criterio de la card: el usuario tiene que enterarse de qué corregir, y eso
    # lo dice el courier en el cuerpo, no el código HTTP.
    it 'propagates the explanation of the courier' do
      expect(response.parsed_body['error']).to include('codigo postal invalido')
    end

    it 'leaves the shipment untouched', :aggregate_failures do
      shipment.reload
      expect(shipment.status).to eq('pending')
      expect(shipment.tracking_number).to be_nil
    end
  end

  # Un 5xx o un timeout no son corregibles desde el request: el fallo es aguas
  # arriba y el 502 lo dice.
  it 'returns 502 when the courier is down' do
    stub_courier(status: 500, body: { error: 'boom' })
    dispatch_shipment

    expect(response).to have_http_status(:bad_gateway)
  end

  # El cuerpo de un tercero puede no ser JSON: una página de error de un proxy,
  # por ejemplo. Se propaga igual, recortada.
  it 'propagates a non-JSON body of the courier' do
    stub_request(:post, 'https://andreani.test/ordenes')
      .to_return(status: 503, body: '<html>Service Unavailable</html>')
    dispatch_shipment

    expect(response.parsed_body['error']).to include('Service Unavailable')
  end

  it 'returns 502 when the courier answers without a tracking number' do
    stub_courier(body: { etiqueta: 'https://l.test/1.pdf' })
    dispatch_shipment

    expect(response).to have_http_status(:bad_gateway)
  end

  describe 'request contract' do
    it 'returns 400 without the integration' do
      dispatch_shipment(integration_id: '')

      expect(response).to have_http_status(:bad_request)
    end

    it 'returns 400 without the origin warehouse' do
      dispatch_shipment(warehouse_id: '')

      expect(response).to have_http_status(:bad_request)
    end

    it 'returns 422 when the chosen integration cannot dispatch' do
      quoting = courier_service('Andreani - Cotización', uri: 'https://andreani.test/tarifas',
                                                         response_mapper: { 'precio' => 'shipping_cost' })
      only_quotes = CompanyIntegration.create!(company: company, service: quoting)
      dispatch_shipment(integration_id: only_quotes.id)

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe 'tenant isolation' do
    def foreign
      @foreign ||= Current.set(company_id: nil) do
        other = Company.create!(name: 'Tenant B', tax_id: '30-22222222-2')
        order = Order.create!(company: other, customer_name: 'Beto', customer_zip_code: '1000',
                              customer_address: 'Otra 1')
        { shipment: Shipment.create!(company: other, order: order, status: 'pending'),
          integration: dispatch_integration(other, name: 'Correo Argentino'),
          warehouse: Warehouse.create!(company: other, name: 'Sur', zip_code: '8000',
                                       address: 'Sur 1') }
      end
    end

    it 'returns 404 for a shipment of another company' do
      dispatch_shipment(id: foreign[:shipment].id)

      expect(response).to have_http_status(:not_found)
    end

    it 'returns 404 for an integration of another company' do
      stub_courier
      dispatch_shipment(integration_id: foreign[:integration].id)

      expect(response).to have_http_status(:not_found)
    end

    it 'returns 404 for a warehouse of another company' do
      stub_courier
      dispatch_shipment(warehouse_id: foreign[:warehouse].id)

      expect(response).to have_http_status(:not_found)
    end

    it 'does not dispatch the shipment of another company' do
      dispatch_shipment(id: foreign[:shipment].id)

      expect(foreign[:shipment].reload.status).to eq('pending')
    end
  end
end
