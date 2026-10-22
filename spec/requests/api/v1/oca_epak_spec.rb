# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/seeds/oca').to_s

# OCA e-Pak de punta a punta por la API, con las plantillas de los seeds
# (db/seeds/oca.rb) y las respuestas reales de su entorno de prueba
# (spec/fixtures/oca/, TESIS-186). Si este archivo pasa, OCA funciona sin una
# línea de código propia: lo que se prueba son plantillas sobre el motor
# genérico.
RSpec.describe 'OCA through the generic adapter', type: :request do
  let(:company) { Company.create!(name: 'Norte', tax_id: '30-11111111-1') }
  let(:user) { User.create!(email: 'norte@example.com', password: 'password123', company: company) }
  let(:headers) { auth_headers(user) }
  let(:oca) { company.company_integrations.joins(:service).find_by!(services: { service_name: 'OCA' }) }

  # Lo que dejan los seeds en desarrollo: Norte conectada con la cuenta de
  # prueba pública de OCA, una integración que despacha y otra que cotiza.
  before do
    OcaSeeds.install!
    OcaSeeds.connect_demo!(company)
  end

  def endpoint(method) = "#{OcaSeeds.base_uri}/#{method}"

  def stub_oca(method, fixture)
    stub_request(:post, endpoint(method)).to_return(oca_xml(fixture))
  end

  def auth_headers(user)
    post '/api/v1/auth/login', params: { email: user.email, password: 'password123' },
                               headers: { 'X-Tenant-Slug' => user.company.slug }
    { 'Authorization' => "Bearer #{response.parsed_body['token']}" }
  end

  def warehouse
    @warehouse ||= Warehouse.create!(company: company, name: 'Satélite', zip_code: 'B1602',
                                     address: 'Calle 25 N° 456', city: 'Florida',
                                     province: 'Buenos Aires')
  end

  def product
    @product ||= Product.create!(company: company, sku: 'NOR-1', name: 'Switch', weight: 2.5,
                                 length_cm: 20, width_cm: 20, height_cm: 20)
  end

  def order
    @order ||= Order.create!(
      company: company, customer_name: 'Cliente Ficticio', customer_document: '20-00000000-0',
      customer_address: 'Calle 50 N° 742', customer_zip_code: '1900', customer_city: 'La Plata',
      customer_province: 'Buenos Aires', total_amount: 15_000,
      order_items: [OrderItem.new(product: product, warehouse: warehouse, quantity: 1,
                                  unit_price: 15_000)]
    )
  end

  def shipment
    @shipment ||= Shipment.create!(company: company, order: order, status: 'pending')
  end

  def dispatched_shipment
    shipment.update!(company_integration: oca, tracking_number: '1217400000000340668',
                     external_reference: '20914118', status: 'ready_to_ship')
    shipment
  end

  describe 'quoting a draft (POST /api/v1/quotes)' do
    def quote(**extra)
      post '/api/v1/quotes', headers: headers, as: :json, params: {
        quote: { origin_warehouse_id: warehouse.id, destination_zip_code: 'B1900ABC',
                 destination_city: 'La Plata', destination_province: 'Buenos Aires',
                 items: [{ product_id: product.id, quantity: 2 }], **extra }
      }
    end

    context 'when OCA covers the destination' do
      before do
        stub_oca('Tarifar_Envio_Corporativo', 'quote')
        quote(declared_value: '15000')
      end

      it 'offers OCA with the price and term of its answer' do
        expect(response.parsed_body['data']).to contain_exactly(
          include('provider_name' => 'OCA', 'dispatch_integration_id' => oca.id,
                  'shipping_cost' => '181.92', 'estimated_days' => 1)
        )
      end

      it 'sends every parameter OCA requires, as a form' do
        expect(WebMock).to have_requested(:post, endpoint('Tarifar_Envio_Corporativo')).with(
          body: { 'PesoTotal' => '5', 'VolumenTotal' => '0.016', 'CodigoPostalOrigen' => '1602',
                  'CodigoPostalDestino' => '1900', 'CantidadPaquetes' => '1', 'ValorDeclarado' => '15000',
                  'Cuit' => '30-53625919-4', 'Operativa' => '64665' }
        )
      end
    end

    it 'quotes with a declared value of 0 when the draft does not say it' do
      stub_oca('Tarifar_Envio_Corporativo', 'quote')
      quote
      expect(WebMock).to have_requested(:post, endpoint('Tarifar_Envio_Corporativo'))
        .with(body: hash_including('ValorDeclarado' => '0'))
    end

    it 'leaves OCA out when it does not cover the destination' do
      stub_oca('Tarifar_Envio_Corporativo', 'quote_error')
      quote
      expect(response.parsed_body['data']).to eq([])
    end

    # TESIS-188: el CP ilegible viajaba vacío, OCA contestaba un error y
    # desaparecía de las opciones sin que quedara dicho por qué.
    context 'when the zip code of the destination cannot be read' do
      before do
        stub_oca('Tarifar_Envio_Corporativo', 'quote')
        allow(Rails.logger).to receive(:info).and_call_original
        quote(destination_zip_code: 'La Plata')
      end

      it 'leaves OCA out without calling it', :aggregate_failures do
        expect(response.parsed_body['data']).to eq([])
        expect(WebMock).not_to have_requested(:post, endpoint('Tarifar_Envio_Corporativo'))
      end

      it 'logs why OCA is not among the options' do
        expect(Rails.logger).to have_received(:info)
          .with(/OCA - Cotización left out of the quote: .*destination_postal_code/)
      end
    end

    # Antes cotizaba un paquete de 0 kg y 0 m³.
    it 'does not quote a product without its weight', :aggregate_failures do
      stub_oca('Tarifar_Envio_Corporativo', 'quote')
      product.update!(weight: 0)
      quote
      expect(response.parsed_body['data']).to eq([])
      expect(WebMock).not_to have_requested(:post, endpoint('Tarifar_Envio_Corporativo'))
    end
  end

  describe 'dispatching (POST /api/v1/shipments/:id/dispatch)' do
    def dispatch_with_oca
      post "/api/v1/shipments/#{shipment.id}/dispatch", headers: headers, as: :json, params: {
        dispatch: { company_integration_id: oca.id, origin_warehouse_id: warehouse.id,
                    shipping_cost: '181.92' }
      }
    end

    context 'when OCA accepts it' do
      let(:sent_form) { {} }

      before do
        stub_request(:post, endpoint('IngresoORMultiplesRetiros_v2')).to_return do |request|
          sent_form.merge!(URI.decode_www_form(request.body).to_h)
          oca_xml('dispatch')
        end
        dispatch_with_oca
      end

      def sent_xml = Nokogiri::XML(sent_form.fetch('xml_Datos'))

      it 'stores the shipment number, the pickup order and a printable label' do
        expect(response.parsed_body).to include(
          'tracking_number' => '1217400000000340668', 'external_reference' => '20914118',
          'status' => 'ready_to_ship', 'label_available' => true, 'shipping_label_url' => nil
        )
      end

      it 'sends the account as parameters' do
        expect(sent_form).to include('usr' => 'test@oca.com.ar', 'psw' => '123456',
                                     'ConfirmarRetiro' => 'true', 'ArchivoCliente' => '')
      end

      it 'sends the pickup point and the account number in the XML', :aggregate_failures do
        expect(sent_xml.at('cabecera')['nrocuenta']).to eq('111757/001')
        expect(sent_xml.at('origen').to_h).to include('calle' => 'Calle 25', 'nro' => '456', 'cp' => '1602',
                                                      'localidad' => 'Florida', 'centrocosto' => '1')
      end

      it 'sends the recipient and the parcel in the XML', :aggregate_failures do
        expect(sent_xml.at('envio').to_h).to match('idoperativa' => '64665', 'nroremito' => /\AOS-#{shipment.id}-\d{12}\z/)
        expect(sent_xml.at('destinatario').to_h).to include('apellido' => 'Cliente Ficticio', 'calle' => 'Calle 50',
                                                            'nro' => '742', 'cp' => '1900')
        expect(sent_xml.at('paquete').to_h).to include('alto' => '20', 'peso' => '2.5', 'valor' => '15000')
      end
    end

    it 'answers 422 with the reason when OCA rejects the dispatch', :aggregate_failures do
      stub_oca('IngresoORMultiplesRetiros_v2', 'dispatch_error')
      dispatch_with_oca
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to eq('OCA returned errors: Usuario o contraseña incorrectos')
    end

    # Antes pedía el retiro de una caja de 1 cm de lado.
    it 'answers 422 without calling OCA when a product has no measures', :aggregate_failures do
      product.update!(length_cm: nil)
      dispatch_with_oca
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to eq("Para despachar con OCA falta el largo de “#{product.name}”.")
      expect(WebMock).not_to have_requested(:post, endpoint('IngresoORMultiplesRetiros_v2'))
    end

    # TESIS-188: la otra forma del rechazo, un bulto en `DetalleRechazos`.
    it 'answers 422 with the reason when OCA rejects the parcel', :aggregate_failures do
      stub_oca('IngresoORMultiplesRetiros_v2', 'dispatch_rejected')
      dispatch_with_oca
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to eq('OCA returned errors: El Codigo Postal de destino no es valido para la operativa')
      expect(shipment.reload).to have_attributes(status: 'pending', tracking_number: nil)
    end

    it 'answers 422 without calling OCA when the zip code cannot be read', :aggregate_failures do
      order.update!(customer_zip_code: 'La Plata')
      dispatch_with_oca
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to eq('Para despachar con OCA, el código postal del destino («La Plata») no es válido.')
      expect(WebMock).not_to have_requested(:post, endpoint('IngresoORMultiplesRetiros_v2'))
    end

    # Varios productos van en un solo bulto consolidado (TESIS-185): el alta
    # lleva un `<paquete>` con el peso de todos.
    context 'when the order has several lines' do
      let(:sent_form) { {} }

      before do
        router = Product.create!(company: company, sku: 'NOR-2', name: 'Router', weight: 1.5,
                                 length_cm: 30, width_cm: 20, height_cm: 10)
        order.order_items.create!(product: router, warehouse: warehouse, quantity: 2, unit_price: 5_000)
        stub_request(:post, endpoint('IngresoORMultiplesRetiros_v2')).to_return do |request|
          sent_form.merge!(URI.decode_www_form(request.body).to_h)
          oca_xml('dispatch')
        end
        dispatch_with_oca
      end

      it 'sends them as one parcel with the weight of all of them', :aggregate_failures do
        expect(response).to have_http_status(:ok)
        parcels = Nokogiri::XML(sent_form.fetch('xml_Datos')).search('paquete')
        expect(parcels.pluck('peso')).to eq(['5.5'])
      end
    end

    # El despacho no es idempotente (ADR-022): si OCA no contesta a tiempo, el
    # envío queda sin despachar para volver a intentarlo.
    it 'answers 502 and keeps the shipment pending when OCA times out', :aggregate_failures do
      stub_request(:post, endpoint('IngresoORMultiplesRetiros_v2')).to_timeout
      dispatch_with_oca
      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body['error']).to start_with('OCA request failed')
      expect(shipment.reload).to have_attributes(status: 'pending', tracking_number: nil)
    end

    it 'answers 502 when OCA fails with a missing parameter', :aggregate_failures do
      stub_request(:post, endpoint('IngresoORMultiplesRetiros_v2'))
        .to_return(status: 500, body: oca_fixture('missing_parameter.txt'))
      dispatch_with_oca
      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body['error']).to include('Missing parameter: Operativa')
    end
  end

  describe 'the label (GET /api/v1/shipments/:id/label)' do
    def label_of(target) = get("/api/v1/shipments/#{target.id}/label", headers: headers)

    context 'when OCA has it' do
      before do
        stub_request(:post, endpoint('GetPdfDeEtiquetasPorOrdenOrNumeroEnvio'))
          .with(body: { 'idOrdenRetiro' => '20914118', 'nroEnvio' => '1217400000000340668',
                        'logisticaInversa' => 'false' })
          .to_return(oca_xml('label'))
        label_of(dispatched_shipment)
      end

      it 'answers the PDF inline', :aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq('application/pdf')
        expect(response.headers['Content-Disposition']).to start_with('inline')
      end

      # El front guarda el PDF con este nombre: lo lee del header, que CORS
      # le expone (TESIS-188).
      it 'names the file after the tracking number' do
        expect(response.headers['Content-Disposition'])
          .to include('filename="etiqueta-1217400000000340668.pdf"')
      end

      it 'decodes the document OCA sends in base64', :aggregate_failures do
        expect(response.body).to start_with('%PDF-1.4')
        expect(response.body.bytesize).to eq(10_059)
      end
    end

    it 'answers 502 when OCA answers a text instead of the PDF', :aggregate_failures do
      stub_oca('GetPdfDeEtiquetasPorOrdenOrNumeroEnvio', 'label_not_found')
      label_of(dispatched_shipment)
      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body['error']).to end_with('No se encontraron etiquetas para los parámetros indicados')
    end

    it 'answers 404 before the dispatch' do
      label_of(shipment)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'tracking (the periodic query, ADR-014)' do
    def poll
      Current.set(company_id: company.id) do
        Shipments::PollTrackingStatus.new(company_integration: oca,
                                          shipment_ids: [dispatched_shipment.id]).call
      end
    end

    def stub_state(estado)
      body = oca_fixture('tracking.xml').sub('<Estado>En proceso de Retiro</Estado>', "<Estado>#{estado}</Estado>")
      stub_request(:post, endpoint('GetEnvioEstadoActual'))
        .with(body: { 'numeroEnvio' => '1217400000000340668', 'ordenRetiro' => '20914118' })
        .to_return(status: 200, body: body)
    end

    # OCA informa la admisión después del retiro, y sólo con el día.
    it 'does not take a picked up shipment back to ready to ship', :aggregate_failures do
      stub_state('Retirado')
      poll
      stub_state('En proceso de Admision')
      expect(poll.map(&:internal_status)).to eq(['in_transit'])
      expect(dispatched_shipment.reload.status).to eq('in_transit')
    end

    # La consulta se repite cada 30 minutos con el mismo estado: el segundo
    # poll no escribe otro evento.
    it 'does not register the same state twice on the next poll', :aggregate_failures do
      stub_state('En Tránsito a Sucursal Destino')
      expect(poll.size).to eq(1)
      expect(poll).to eq([])
      expect(dispatched_shipment.shipment_events.count).to eq(1)
    end

    it 'registers a state the mapper does not know as informative', :aggregate_failures do
      stub_state('Retirado')
      poll
      stub_state('Reprogramado por el cliente')
      expect(poll.first).to have_attributes(external_status: 'Reprogramado por el cliente', internal_status: 'in_transit')
      expect(dispatched_shipment.reload.status).to eq('in_transit')
    end

    # TESIS-188: con un final, el envío sale de la consulta periódica.
    it 'stops asking OCA once the shipment is returned', :aggregate_failures do
      stub_state('Devuelto al Remitente')
      poll
      expect(Shipment.unscoped.in_flight.where(id: dispatched_shipment.id)).to be_empty
      expect(poll).to eq([])
      expect(WebMock).to have_requested(:post, endpoint('GetEnvioEstadoActual')).once
    end

    {
      'En proceso de Retiro' => 'ready_to_ship',
      'Retirado' => 'in_transit',
      'En proceso de Admision' => 'in_transit',
      'En Tránsito a Sucursal Destino' => 'in_transit',
      'Visita - Domicilio Cerrado' => 'in_transit',
      'Entregado' => 'delivered',
      'Estado de Visita ONLINE (Entregado)' => 'delivered',
      # Una visita fallida no es un final: OCA vuelve a intentar.
      'No entregado - Domicilio Cerrado' => 'in_transit',
      # Los finales que no son una entrega (TESIS-188).
      'Devuelto al Remitente' => 'returned',
      'Devolución a origen' => 'returned',
      'Anulado' => 'cancelled',
      'Anulada por el cliente' => 'cancelled',
      'Siniestrado' => 'cancelled',
      'Siniestro - Extravío' => 'cancelled'
    }.each do |estado, status|
      it "registers «#{estado}» as #{status}", :aggregate_failures do
        stub_state(estado)
        expect(poll.map { |event| [event.external_status, event.internal_status] }).to eq([[estado, status]])
        expect(dispatched_shipment.reload.status).to eq(status)
      end
    end
  end

  it 'tests the connection with the account of the company' do
    stub_request(:post, endpoint('GetOperativasByUsuario'))
      .with(body: { 'usr' => 'test@oca.com.ar', 'psw' => '123456' }).to_return(oca_xml('connection_test'))
    expect(Integrations::TestConnection.new(company_integration: oca).call)
      .to eq(ok: true, message: 'OCA: connection verified')
  end
end
