# frozen_string_literal: true

require 'rails_helper'

# TESIS-162: lo que abre la campanita. No hay tabla de notificaciones: la
# actividad se deriva de lo que el sistema ya registra, así que no puede
# desincronizarse de los hechos.
RSpec.describe 'Activity API', type: :request do
  let(:company) { Company.create!(name: 'Tenant A', tax_id: '30-11111111-1') }
  let(:user) { User.create!(email: 'a@example.com', password: 'password123', company: company) }
  let(:headers) { auth_headers(user) }

  def auth_headers(for_user)
    post '/api/v1/auth/login', params: { email: for_user.email, password: 'password123' },
                               headers: { 'X-Tenant-Slug' => for_user.company.slug }
    { 'Authorization' => "Bearer #{response.parsed_body['token']}" }
  end

  def create_order(owner: company, customer: 'Ana', at: Time.current, external: nil)
    Current.set(company_id: owner.id) do
      Order.create!(company: owner, customer_name: customer, status: 'paid',
                    external_order_id: external, created_at: at)
    end
  end

  def courier_integration(owner: company)
    service = Service.create!(service_name: "Andreani #{SecureRandom.hex(4)}", type: 'courier',
                              http_method: 'POST', uri: 'https://api.andreani.test')
    Current.set(company_id: owner.id) { CompanyIntegration.create!(company: owner, service: service) }
  end

  def dispatch_order(order, at: Time.current, tracking: 'AND-1', owner: company)
    Current.set(company_id: owner.id) do
      shipment = Shipment.create!(company: owner, order: order, status: 'ready_to_ship',
                                  tracking_number: tracking,
                                  company_integration: courier_integration(owner: owner))
      ShipmentEvent.create!(shipment: shipment, internal_status: 'ready_to_ship',
                            external_status: 'Despachado', occurred_at: at)
      shipment
    end
  end

  def fail_event(at: Time.current, owner: company)
    Current.set(company_id: owner.id) do
      FailedEvent.create!(company: owner, event_type: 'order_ingestion', direction: 'inbound',
                          payload: {}, created_at: at)
    end
  end

  def feed
    get '/api/v1/activity', headers: headers
    response.parsed_body['data']
  end

  it 'returns 401 without a token' do
    get '/api/v1/activity'
    expect(response).to have_http_status(:unauthorized)
  end

  it 'answers with data and no meta: it is a panel, not a paginated listing' do
    get '/api/v1/activity', headers: headers

    expect(response.parsed_body.keys).to eq(['data'])
  end

  describe 'what it reports' do
    it 'reports a sale that came in', :aggregate_failures do
      order = create_order(customer: 'Distribuidora Sur', external: 'SHOP-99')

      entry = feed.first
      expect(entry).to include('type' => 'order_created', 'order_id' => order.id,
                               'customer_name' => 'Distribuidora Sur',
                               'external_order_id' => 'SHOP-99')
    end

    # Una venta cargada a mano no tiene id externo, y eso es lo que la distingue
    # de una de canal en la pantalla.
    it 'tells a manual sale apart by its missing external id' do
      create_order

      expect(feed.first['external_order_id']).to be_nil
    end

    # `shipments` no guarda cuándo se despachó: lo dice el primer evento
    # `ready_to_ship` de la bitácora, igual que en los reportes.
    it 'reports a dispatch with its courier and its tracking', :aggregate_failures do
      shipment = dispatch_order(create_order, tracking: 'AND-500')

      entry = feed.find { |event| event['type'] == 'shipment_dispatched' }
      expect(entry).to include('shipment_id' => shipment.id, 'order_id' => shipment.order_id,
                               'tracking_number' => 'AND-500')
      expect(entry['courier']).to start_with('Andreani')
    end

    it 'reports an event that fell to the retry queue', :aggregate_failures do
      failure = fail_event

      entry = feed.find { |event| event['type'] == 'event_failed' }
      expect(entry).to include('failed_event_id' => failure.id,
                               'event_type' => 'order_ingestion', 'status' => 'pending')
    end


    # Los tres datos que el feed deja en null cuando no hay: la orden sin total
    # (las anteriores a TESIS-114 no tienen líneas con qué calcularlo), el envío
    # sin courier y el evento fallido sin integración (los de la ingesta por
    # webhook pueden no tener una todavía). Null y no un texto de relleno: la
    # pantalla decide cómo se muestra lo que falta.
    # Una orden sin líneas no tiene con qué calcular su total (TESIS-114).
    it 'leaves the total of an order that has none in null' do
      create_order

      expect(feed.first['total_amount']).to be_nil
    end

    def dispatch_without_courier
      Current.set(company_id: company.id) do
        shipment = Shipment.create!(company: company, order: create_order,
                                    status: 'ready_to_ship', tracking_number: 'SIN-COURIER')
        ShipmentEvent.create!(shipment: shipment, internal_status: 'ready_to_ship',
                              external_status: 'Despachado', occurred_at: Time.current)
      end
    end

    it 'leaves the courier in null for a shipment that has none' do
      dispatch_without_courier

      expect(feed.find { |event| event['type'] == 'shipment_dispatched' }['courier']).to be_nil
    end

    it 'leaves the integration in null for a failure that has none' do
      fail_event

      expect(feed.find { |event| event['type'] == 'event_failed' }['integration']).to be_nil
    end

    it 'has nothing to report for a company where nothing happened' do
      expect(feed).to eq([])
    end
  end

  describe 'how it is ordered and bounded' do
    it 'puts the most recent first, mixing the three sources', :aggregate_failures do
      create_order(at: 3.days.ago)
      dispatch_order(create_order(at: 5.days.ago), at: 1.day.ago)
      fail_event(at: 2.days.ago)

      expect(feed.pluck('type'))
        .to eq(%w[shipment_dispatched event_failed order_created order_created])
    end

    it 'defaults to the last twenty' do
      25.times { |i| create_order(at: i.minutes.ago) }

      expect(feed.size).to eq(Activity::BuildFeed::DEFAULT_LIMIT)
    end

    it 'honours a smaller limit' do
      5.times { |i| create_order(at: i.minutes.ago) }

      get '/api/v1/activity', params: { limit: 2 }, headers: headers

      expect(response.parsed_body['data'].size).to eq(2)
    end

    # Es un desplegable con techo, no un listado: sin tope, un `?limit=` grande
    # haría tres consultas sin límite.
    it 'caps a limit that asks for too much' do
      60.times { |i| create_order(at: i.minutes.ago) }

      get '/api/v1/activity', params: { limit: 1_000 }, headers: headers

      expect(response.parsed_body['data'].size).to eq(Activity::BuildFeed::MAX_LIMIT)
    end

    it 'falls back to the default for a limit that is not a number' do
      3.times { |i| create_order(at: i.minutes.ago) }

      get '/api/v1/activity', params: { limit: 'muchas' }, headers: headers

      expect(response.parsed_body['data'].size).to eq(3)
    end
  end

  describe 'tenant isolation' do
    let(:other_company) { Company.create!(name: 'Tenant B', tax_id: '30-22222222-2') }

    it 'leaves out the orders of another company' do
      create_order(owner: other_company, customer: 'Ajena')

      expect(feed).to eq([])
    end

    # `ShipmentEvent` no tiene company_id: su aislamiento entra por el join con
    # `Shipment`, así que vale la pena probarlo aparte.
    it 'leaves out the dispatches of another company' do
      dispatch_order(create_order(owner: other_company), owner: other_company)

      expect(feed).to eq([])
    end

    it 'leaves out the failed events of another company' do
      fail_event(owner: other_company)

      expect(feed).to eq([])
    end
  end
end
