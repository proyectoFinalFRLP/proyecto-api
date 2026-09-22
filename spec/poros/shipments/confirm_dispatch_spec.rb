# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Shipments::ConfirmDispatch, type: :poro do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:warehouse) do
    Warehouse.create!(company: company, name: 'Central', zip_code: '1900', address: 'Calle 1')
  end
  let(:order) do
    Order.create!(company: company, customer_name: 'Juan Pérez', customer_document: '20-1-9',
                  customer_zip_code: '5000', customer_address: 'Av. Siempreviva 742')
  end
  let(:shipment) { Shipment.create!(company: company, order: order, status: 'pending') }
  let(:integration) { dispatch_integration }

  before { Current.company_id = company.id }

  # Plantilla de despacho: declara de dónde leer el número de seguimiento y la
  # etiqueta, que es lo que la hace reconocible como tal (Service#dispatches_shipment?).
  def dispatch_integration(name: 'Andreani', **attrs)
    service = courier_service(name, uri: 'https://andreani.test/ordenes',
                                    request_mapper: { 'destino.cp' => 'destination_zip_code' },
                                    response_mapper: { 'bulto.0.numeroDeEnvio' => 'tracking_number',
                                                       'etiqueta.url' => 'shipping_label_url' })
    CompanyIntegration.create!({ company: company, service: service,
                                 credentials: { 'access_token' => 'T' } }.merge(attrs))
  end

  def stub_courier(body: { bulto: [{ numeroDeEnvio: 'AND-999' }], etiqueta: { url: 'https://l.test/1.pdf' } },
                   status: 200)
    stub_request(:post, 'https://andreani.test/ordenes')
      .to_return(status: status, body: body.to_json, headers: { 'Content-Type' => 'application/json' })
  end

  def dispatch(target = shipment, using: integration)
    described_class.new(shipment: target, company_integration: using,
                        origin_warehouse: warehouse).call
  end

  # Corre el caso de uso tragándose el error esperado: deja el camino ejecutado
  # para poder afirmar sobre lo que quedó (o no) en la base.
  def attempt_dispatch(target = shipment, using: integration)
    dispatch(target, using: using)
  rescue Shipments::AlreadyDispatchedError, Shipments::DispatchResponseError,
         Shipments::InvalidCourierIntegrationError, Integrations::AdapterExecutionError
    nil
  end

  describe 'a successful dispatch' do
    before { stub_courier }

    it 'saves the tracking number the courier returned' do
      expect(dispatch.reload.tracking_number).to eq('AND-999')
    end

    it 'saves the url of the label' do
      expect(dispatch.reload.shipping_label_url).to eq('https://l.test/1.pdf')
    end

    it 'assigns the chosen courier to the shipment' do
      expect(dispatch.reload.company_integration_id).to eq(integration.id)
    end

    it 'leaves the shipment ready to ship' do
      expect { dispatch }.to change { shipment.reload.status }.from('pending').to('ready_to_ship')
    end

    it 'records the first event of the log', :aggregate_failures do
      expect { dispatch }.to change(ShipmentEvent, :count).by(1)

      event = shipment.shipment_events.last
      expect(event.internal_status).to eq('ready_to_ship')
      expect(event.external_status).to eq('Etiqueta generada')
    end

    # El destinatario y el peso van en el cuerpo porque son lo que la etiqueta
    # imprime; sin ellos el courier no puede armarla.
    it 'sends the destination of the order to the courier' do
      dispatch

      expect(a_request(:post, 'https://andreani.test/ordenes')
        .with(body: hash_including('destino' => { 'cp' => '5000' }))).to have_been_made
    end
  end

  describe 'when the courier rejects the request' do
    before { stub_courier(status: 422, body: { error: 'codigo postal invalido' }) }

    it 'raises the error of the adapter' do
      expect { dispatch }.to raise_error(Integrations::AdapterExecutionError)
    end

    # Criterio de la card: si el courier rechaza, los datos locales no cambian.
    it 'leaves the shipment untouched', :aggregate_failures do
      attempt_dispatch
      shipment.reload
      expect(shipment.status).to eq('pending')
      expect(shipment.tracking_number).to be_nil
      expect(shipment.company_integration_id).to be_nil
    end

    it 'records no event' do
      expect { attempt_dispatch }.not_to change(ShipmentEvent, :count)
    end
  end

  # Sin número de seguimiento el envío no se puede seguir ni emparejar con los
  # eventos que el courier empuje después (TESIS-48).
  describe 'when the courier answers without a tracking number' do
    before { stub_courier(body: { etiqueta: { url: 'https://l.test/1.pdf' } }) }

    it 'raises' do
      expect { dispatch }.to raise_error(Shipments::DispatchResponseError)
    end

    it 'leaves the shipment pending' do
      attempt_dispatch

      expect(shipment.reload.status).to eq('pending')
    end
  end

  # La etiqueta sí puede faltar: no todos los proveedores devuelven una URL.
  it 'dispatches without a label url' do
    stub_courier(body: { bulto: [{ numeroDeEnvio: 'AND-111' }] })

    expect(dispatch.reload.shipping_label_url).to be_nil
  end

  describe 'when the shipment is not pending' do
    let(:shipment) do
      Shipment.create!(company: company, order: order, status: 'in_transit',
                       tracking_number: 'AND-1', company_integration: integration)
    end

    it 'refuses to dispatch it again' do
      expect { dispatch }.to raise_error(Shipments::AlreadyDispatchedError)
    end

    # Se valida antes de llamar: una etiqueta de más se paga.
    it 'does not call the courier' do
      stub = stub_courier
      attempt_dispatch

      expect(stub).not_to have_been_requested
    end
  end

  # Criterio de la card al pie de la letra: 409 si ya tiene tracking, aunque el
  # estado diga otra cosa. Desde Avo se puede devolver un envío a `pending` sin
  # borrarle el número.
  describe 'when a pending shipment already has a tracking number' do
    let(:shipment) do
      Shipment.create!(company: company, order: order, status: 'pending', tracking_number: 'AND-1')
    end

    it 'refuses to dispatch it' do
      expect { dispatch }.to raise_error(Shipments::AlreadyDispatchedError, /AND-1/)
    end

    it 'does not call the courier' do
      stub = stub_courier
      attempt_dispatch

      expect(stub).not_to have_been_requested
    end
  end

  # La carrera se reproduce sin dos transacciones: mientras "esperamos al
  # courier", otro request despacha el mismo envío en la base. Si alguien saca
  # el `lock!` o la revalidación de adentro de la transacción porque "ya se
  # validó arriba", esto se pone en rojo en vez de pisar el tracking del otro.
  describe 'when another request dispatches the shipment while the courier answers' do
    before do
      stub_request(:post, 'https://andreani.test/ordenes').to_return do
        Shipment.find(shipment.id).update!(status: 'ready_to_ship', tracking_number: 'AND-OTHER')
        { status: 200, headers: { 'Content-Type' => 'application/json' },
          body: { bulto: [{ numeroDeEnvio: 'AND-999' }] }.to_json }
      end
    end

    it 'loses the race with a conflict' do
      expect { dispatch }.to raise_error(Shipments::AlreadyDispatchedError)
    end

    it 'keeps the tracking number of the winner' do
      attempt_dispatch

      expect(shipment.reload.tracking_number).to eq('AND-OTHER')
    end

    it 'records no event' do
      expect { attempt_dispatch }.not_to change(ShipmentEvent, :count)
    end
  end

  describe 'when the chosen integration cannot dispatch' do
    def expect_rejection(integration)
      expect { dispatch(using: integration) }
        .to raise_error(Shipments::InvalidCourierIntegrationError)
    end

    it 'rejects a sales channel' do
      service = Service.create!(service_name: 'Tiendanube', type: 'ecommerce', http_method: 'POST',
                                uri: 'https://tn.test/orders', request_mapper: {},
                                response_mapper: { 'id' => 'tracking_number' },
                                request_value_mapper: {}, response_value_mapper: {})
      expect_rejection(CompanyIntegration.create!(company: company, service: service))
    end

    it 'rejects an inactive integration' do
      expect_rejection(dispatch_integration(name: 'Apagado', is_active: false))
    end

    # La plantilla de cotización no trae tracking: pedirle una etiqueta sería
    # llamar al endpoint de tarifas esperando otra cosa.
    it 'rejects a template that only knows how to quote' do
      service = courier_service('Andreani - Cotización', uri: 'https://andreani.test/tarifas',
                                                         request_mapper: {},
                                                         response_mapper: { 'precio' => 'shipping_cost' })
      expect_rejection(CompanyIntegration.create!(company: company, service: service))
    end

    # Mapea el número de seguimiento —para emparejar los elementos de la
    # respuesta— y aun así no despacha. El mensaje tiene que decir eso, no que
    # le falta el mapeo que sí tiene.
    def tracking_integration
      tracking = courier_service('Correo - Seguimiento', uri: 'https://correo.test/envios/estado',
                                                         response_mapper: { 'envios[].numero' => 'tracking_number',
                                                                            'envios[].estado' => 'external_status' })
      courier_service('Correo', tracking_service: tracking)
      CompanyIntegration.create!(company: company, service: tracking)
    end

    it 'rejects the tracking template of a courier, saying so' do
      expect { dispatch(using: tracking_integration) }
        .to raise_error(Shipments::InvalidCourierIntegrationError, /answers tracking queries/)
    end

    it 'does not call the courier' do
      stub = stub_courier
      expect_rejection(dispatch_integration(name: 'Apagado', is_active: false))

      expect(stub).not_to have_been_requested
    end
  end
end
