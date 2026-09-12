# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Shipments API', type: :request do
  let(:company) { Company.create!(name: 'Tenant A', tax_id: '30-11111111-1') }
  let(:user) { User.create!(email: 'a@example.com', password: 'password123', company: company) }
  let(:headers) { auth_headers(user) }

  def auth_headers(user)
    post '/api/v1/auth/login', params: { email: user.email, password: 'password123' }
    { 'Authorization' => "Bearer #{response.parsed_body['token']}" }
  end

  def order_for(customer, owner: company)
    Order.create!(company: owner, customer_name: customer, customer_zip_code: '5000',
                  customer_address: 'Av. Siempreviva 742')
  end

  def courier(name)
    service = Service.create!(service_name: name, type: 'courier', http_method: 'POST',
                              uri: "https://#{name.downcase}.test/track",
                              request_mapper: {}, response_mapper: {},
                              request_value_mapper: {}, response_value_mapper: {})
    CompanyIntegration.create!(company: company, service: service,
                               credentials: { 'access_token' => 'T' }, is_active: true)
  end

  def shipment_for(customer, status: 'pending', integration: nil, tracking_number: nil,
                   shipping_cost: nil)
    Shipment.create!(company: company, order: order_for(customer), status: status,
                     company_integration: integration, tracking_number: tracking_number,
                     shipping_cost: shipping_cost)
  end

  # assign_current_company pisa el company: manual cuando Current.company_id está
  # seteado (puede quedar de un request previo), así que se fuerza nil para que
  # el fixture nazca SIEMPRE en la otra empresa.
  def foreign_shipment
    @foreign_shipment ||= Current.set(company_id: nil) do
      other = Company.create!(name: 'Tenant B', tax_id: '30-22222222-2')
      Shipment.create!(company: other, order: order_for('Ajena', owner: other),
                       status: 'in_transit')
    end
  end

  def count_queries(matching:, &block)
    count = 0
    counter = lambda do |_name, _started, _finished, _id, payload|
      count += 1 if payload[:sql].to_s.match?(matching)
    end

    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &block)

    count
  end

  describe 'GET /api/v1/shipments' do
    it 'returns 401 without a token' do
      get '/api/v1/shipments'
      expect(response).to have_http_status(:unauthorized)
    end

    context 'when authenticated' do
      before do
        shipment_for('Ana', status: 'in_transit', integration: courier('Andreani'),
                            tracking_number: 'AND-1', shipping_cost: 12_500.5)
        shipment_for('Beto', status: 'pending')
        foreign_shipment

        get '/api/v1/shipments', headers: headers
      end

      it 'returns only the shipments of the current company', :aggregate_failures do
        body = response.parsed_body
        expect(response).to have_http_status(:ok)
        expect(body['data'].length).to eq(2)
        expect(body['data'].pluck('status')).to match_array(%w[in_transit pending])
      end

      it 'includes the courier of each shipment for the carrier column' do
        row = response.parsed_body['data'].find { |s| s['tracking_number'] == 'AND-1' }
        expect(row['courier']).to include('name' => 'Andreani')
      end

      # El estado inicial de un envío: sin courier todavía (se asigna al
      # confirmar el despacho). La fila tiene que salir igual.
      it 'serializes a shipment with no courier assigned', :aggregate_failures do
        row = response.parsed_body['data'].find { |s| s['tracking_number'].nil? }
        expect(row['courier']).to be_nil
        expect(row['status']).to eq('pending')
      end

      it 'exposes shipping_cost as a number', :aggregate_failures do
        costs = response.parsed_body['data'].pluck('shipping_cost')
        expect(costs).to include(12_500.5)
        expect(costs).to include(nil)
      end

      it 'includes pagination metadata', :aggregate_failures do
        meta = response.parsed_body['meta']
        expect(meta['page']).to eq(1)
        expect(meta['per_page']).to eq(20)
        expect(meta['total']).to eq(2)
      end

      it 'honours page and per_page params', :aggregate_failures do
        get '/api/v1/shipments', params: { page: 1, per_page: 1 }, headers: headers

        expect(response.parsed_body['data'].length).to eq(1)
        expect(response.parsed_body['meta']).to include('page' => 1, 'per_page' => 1, 'total' => 2)
      end
    end

    describe 'filters' do
      before do
        shipment_for('Ana', status: 'in_transit')
        shipment_for('Beto', status: 'pending')
        shipment_for('Cora', status: 'delivered')
      end

      it 'filters the rows by status' do
        get '/api/v1/shipments', params: { status: 'in_transit' }, headers: headers

        expect(response.parsed_body['data'].pluck('status')).to eq(['in_transit'])
      end

      # El KPI de envíos activos (TESIS-53) lee meta.total con per_page chico:
      # si el total ignorara el filtro, el KPI contaría todos los envíos.
      it 'counts only the filtered rows in meta.total', :aggregate_failures do
        get '/api/v1/shipments', params: { status: 'in_transit', per_page: 1 }, headers: headers

        expect(response.parsed_body['data'].length).to eq(1)
        expect(response.parsed_body['meta']['total']).to eq(1)
      end

      it 'returns an empty page for a status nobody is in', :aggregate_failures do
        get '/api/v1/shipments', params: { status: 'ready_to_ship' }, headers: headers

        expect(response.parsed_body['data']).to eq([])
        expect(response.parsed_body['meta']['total']).to eq(0)
      end

      it 'filters by order_id', :aggregate_failures do
        target = Shipment.find_by(status: 'delivered')
        get '/api/v1/shipments', params: { order_id: target.order_id }, headers: headers

        expect(response.parsed_body['data'].pluck('id')).to eq([target.id])
        expect(response.parsed_body['meta']['total']).to eq(1)
      end
    end

    # La precarga de company_integration: :service es lo único que sostiene la
    # columna Carrier: sin ella, el nombre del courier cuesta dos queries por fila.
    describe 'query count' do
      before do
        3.times { |i| shipment_for("Cliente #{i}", integration: courier("Courier#{i}")) }
        headers
      end

      def queries_against(table)
        count_queries(matching: /FROM "#{table}"/) { get '/api/v1/shipments', headers: headers }
      end

      it 'resolves the courier name without N+1', :aggregate_failures do
        expect(queries_against('company_integrations')).to eq(1)
        expect(queries_against('services')).to eq(1)
        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe 'GET /api/v1/shipments/:id' do
    let(:shipment) do
      shipment_for('Ana', status: 'in_transit', integration: courier('Andreani'),
                          tracking_number: 'AND-1', shipping_cost: 12_500.5)
    end

    it 'returns 401 without a token' do
      get "/api/v1/shipments/#{shipment.id}"
      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns the shipment with its courier', :aggregate_failures do
      get "/api/v1/shipments/#{shipment.id}", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include('id' => shipment.id, 'tracking_number' => 'AND-1',
                                              'order_id' => shipment.order_id)
      expect(response.parsed_body['courier']).to include('name' => 'Andreani')
    end

    context 'with a tracking log' do
      before do
        # Sembrados fuera de orden a propósito: el endpoint tiene que devolver
        # la bitácora cronológica, no el orden de inserción.
        ShipmentEvent.create!(shipment: shipment, internal_status: 'in_transit',
                              external_status: 'En distribución',
                              occurred_at: Time.zone.parse('2026-08-11 08:30:00'))
        ShipmentEvent.create!(shipment: shipment, internal_status: 'ready_to_ship',
                              external_status: 'En preparación',
                              occurred_at: Time.zone.parse('2026-08-10 10:00:00'))

        get "/api/v1/shipments/#{shipment.id}", headers: headers
      end

      it 'returns the events ordered by occurred_at' do
        expect(response.parsed_body['events'].pluck('external_status'))
          .to eq(['En preparación', 'En distribución'])
      end

      it 'exposes both the internal and the external status of each event' do
        expect(response.parsed_body['events'].first)
          .to include('internal_status' => 'ready_to_ship', 'external_status' => 'En preparación')
      end
    end

    it 'returns an empty log for a shipment with no events' do
      get "/api/v1/shipments/#{shipment.id}", headers: headers

      expect(response.parsed_body['events']).to eq([])
    end

    it 'serializes a shipment with no courier assigned', :aggregate_failures do
      pending_shipment = shipment_for('Beto')
      get "/api/v1/shipments/#{pending_shipment.id}", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['courier']).to be_nil
      expect(response.parsed_body['shipping_cost']).to be_nil
    end

    # 404 y no 403: confirmar la existencia del recurso ya sería filtrar
    # información de otro tenant.
    it 'returns 404 for a shipment of another company' do
      get "/api/v1/shipments/#{foreign_shipment.id}", headers: headers

      expect(response).to have_http_status(:not_found)
    end

    it 'returns 404 for an unknown id' do
      get '/api/v1/shipments/0', headers: headers

      expect(response).to have_http_status(:not_found)
    end
  end
end
