require 'rails_helper'

RSpec.describe Service, type: :model do
  subject(:service) do
    described_class.new(service_name: 'Mercado Libre', type: 'ecommerce',
                        uri: 'https://api.ml.com', http_method: 'GET')
  end

  it 'is valid with the required attributes' do
    expect(service).to be_valid
  end

  %i[service_name type uri http_method].each do |attribute|
    it "is invalid without #{attribute}" do
      service.public_send("#{attribute}=", nil)
      expect(service).not_to be_valid
    end
  end

  it 'is invalid with an unknown type' do
    service.type = 'marketplace'
    expect(service).not_to be_valid
  end

  it 'enforces service_name uniqueness' do
    service.save!
    duplicate = described_class.new(service_name: service.service_name, type: 'courier',
                                    uri: 'https://x.com', http_method: 'POST')
    expect(duplicate).not_to be_valid
  end

  it 'does not treat `type` as STI' do
    expect(described_class.new(type: 'ecommerce')).to be_an_instance_of(described_class)
  end

  describe '#ecommerce?' do
    it 'is true for an ecommerce service' do
      service.type = 'ecommerce'
      expect(service.ecommerce?).to be true
    end

    it 'is false for a courier service' do
      service.type = 'courier'
      expect(service.ecommerce?).to be false
    end
  end

  describe '#courier?' do
    it 'is true for a courier service' do
      service.type = 'courier'
      expect(service.courier?).to be true
    end

    it 'is false for an ecommerce service' do
      service.type = 'ecommerce'
      expect(service.courier?).to be false
    end
  end

  # La plantilla declara qué sabe hacer en su propio response_mapper: la que
  # despacha dice de dónde sacar el número de seguimiento, la que cotiza dice de
  # dónde sacar el costo (TESIS-47).
  describe '#dispatches_shipment?' do
    before { service.type = 'courier' }

    it 'is true for a courier template that maps a tracking number' do
      service.response_mapper = { 'bulto.0.numeroDeEnvio' => 'tracking_number' }
      expect(service.dispatches_shipment?).to be true
    end

    it 'is false for a courier template that only knows how to quote' do
      service.response_mapper = { 'tarifa.total' => 'shipping_cost' }
      expect(service.dispatches_shipment?).to be false
    end

    it 'is false for a sales channel, even if it maps a tracking number' do
      service.type = 'ecommerce'
      service.response_mapper = { 'id' => 'tracking_number' }
      expect(service.dispatches_shipment?).to be false
    end
  end

  describe '#answers_tracking?' do
    before do
      service.type = 'courier'
      service.uri = 'https://api.correo.test/envios/:tracking_number/estado'
      service.response_mapper = { 'estado.descripcion' => 'external_status' }
    end

    it 'is true for a courier template queried by tracking number' do
      expect(service.answers_tracking?).to be true
    end

    it 'is true for a batch template that returns a list of shipments' do
      service.uri = 'https://api.correo.test/envios/estado'
      service.response_mapper = { 'envios[].numero' => 'tracking_number',
                                  'envios[].estado' => 'external_status' }
      expect(service.answers_tracking?).to be true
    end

    # Es la plantilla de despacho de un courier con push (ADR-011): mapea el
    # estado para leer el webhook, pero no sabe contestar una consulta.
    it 'is false when the template maps a status but does not say how to ask for it' do
      service.uri = 'https://api.correo.test/ordenes-de-envio'
      expect(service.answers_tracking?).to be false
    end

    it 'is false when the template does not map an external status' do
      service.response_mapper = { 'tarifa.total' => 'shipping_cost' }
      expect(service.answers_tracking?).to be false
    end

    it 'is false for a sales channel' do
      service.type = 'ecommerce'
      expect(service.answers_tracking?).to be false
    end
  end

  describe '#tracks_in_batch?' do
    it 'is true when the tracking number is read from a collection' do
      service.response_mapper = { 'envios[].numero' => 'tracking_number' }
      expect(service.tracks_in_batch?).to be true
    end

    it 'is false when the tracking number is a single value' do
      service.response_mapper = { 'numero' => 'tracking_number' }
      expect(service.tracks_in_batch?).to be false
    end
  end

  # Qué plantilla es de seguimiento lo dice el vínculo, no la forma del mapper:
  # las dos pueden mapear el número de seguimiento desde una colección.
  describe '#dispatches_shipment? next to a tracking template' do
    let(:batch_mapper) do
      { 'envios[].numero' => 'tracking_number', 'envios[].estado' => 'external_status' }
    end

    def template(name, uri)
      described_class.create!(service_name: name, type: 'courier', http_method: 'POST',
                              uri: uri, response_mapper: batch_mapper)
    end

    it 'is false for the template a courier asks for its tracking' do
      tracking = template('Correo - Seguimiento', 'https://api.correo.test/envios/estado')
      template('Correo', 'https://api.correo.test/ordenes').update!(tracking_service: tracking)

      expect(tracking.dispatches_shipment?).to be false
    end

    # La trampa de la review: un endpoint de despacho que contesta una lista
    # tiene la forma de una consulta masiva, y no por eso deja de despachar.
    it 'is true for a dispatch template whose provider answers with a list' do
      dispatch = template('Correo', 'https://api.correo.test/ordenes')

      expect(dispatch.dispatches_shipment?).to be true
    end
  end

  describe '#tracking_template?' do
    it 'is false for a template nobody points at' do
      expect(service.tracking_template?).to be false
    end
  end

  describe 'tracking_service' do
    subject(:courier) do
      described_class.new(service_name: 'Correo', type: 'courier', http_method: 'POST',
                          uri: 'https://api.correo.test/ordenes')
    end

    let(:tracking_template) do
      described_class.create!(service_name: 'Correo - Seguimiento', type: 'courier',
                              http_method: 'GET',
                              uri: 'https://api.correo.test/envios/:tracking_number',
                              response_mapper: { 'estado' => 'external_status' })
    end

    it 'accepts a template that answers tracking queries' do
      courier.tracking_service = tracking_template
      expect(courier).to be_valid
    end

    it 'rejects a template that does not answer tracking queries' do
      courier.tracking_service = described_class.create!(
        service_name: 'Correo - Cotización', type: 'courier', http_method: 'POST',
        uri: 'https://api.correo.test/tarifas', response_mapper: { 'total' => 'shipping_cost' }
      )
      expect(courier).not_to be_valid
    end

    it 'rejects pointing a template at itself' do
      tracking_template.tracking_service = tracking_template
      expect(tracking_template).not_to be_valid
    end

    it 'rejects a tracking template on a sales channel' do
      service.tracking_service = tracking_template
      expect(service).not_to be_valid
    end

    it 'is released when the tracking template is destroyed' do
      courier.update!(tracking_service: tracking_template)
      tracking_template.destroy!
      expect(courier.reload.tracking_service).to be_nil
    end
  end

  it 'persists nested JSONB mappers', :aggregate_failures do
    service.update!(request_mapper: { 'order' => { 'id' => 'external_id' } })
    expect(service.reload.request_mapper).to eq('order' => { 'id' => 'external_id' })
  end

  it 'has many company_integrations' do
    expect(described_class.reflect_on_association(:company_integrations).macro).to eq(:has_many)
  end

  describe 'mapper coercion from String (formularios del backoffice)' do
    it 'parses a valid JSON string into a Hash' do
      service.request_mapper = '{"a": "b"}'
      expect(service.request_mapper).to eq('a' => 'b')
    end

    it 'accepts a Hash untouched' do
      service.request_mapper = { 'a' => 'b' }
      expect(service.request_mapper).to eq('a' => 'b')
    end

    it 'coerces a blank string into an empty Hash' do
      service.request_mapper = '   '
      expect(service.request_mapper).to eq({})
    end

    it 'marks the record invalid on malformed JSON', :aggregate_failures do
      service.request_mapper = '{esto no es json'
      expect(service).not_to be_valid
      expect(service.errors[:request_mapper]).to include('no es un JSON válido')
    end

    it 'marks the record invalid when the JSON is not an object' do
      service.request_mapper = '"solo-un-string"'
      expect(service).not_to be_valid
    end

    it 'keeps the previous value when the new JSON is malformed' do
      service.update!(request_mapper: { 'a' => 'b' })
      service.request_mapper = '{roto'
      expect(service.request_mapper).to eq('a' => 'b')
    end

    it 'becomes valid again when the mapper is reassigned with valid JSON', :aggregate_failures do
      service.request_mapper = '{roto'
      service.request_mapper = '{"a": "b"}'
      expect(service).to be_valid
      expect(service.request_mapper).to eq('a' => 'b')
    end
  end
end
