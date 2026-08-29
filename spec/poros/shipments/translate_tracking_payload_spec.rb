# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Shipments::TranslateTrackingPayload, type: :poro do
  subject(:result) { described_class.new(service: service, payload: payload).call }

  let(:service) do
    Service.create!(
      service_name: 'Andreani',
      type: 'courier',
      uri: 'https://api.andreani.com',
      http_method: 'POST',
      response_mapper: {
        'envio.numeroDeEnvio' => 'tracking_number',
        'evento.estado' => 'external_status',
        'evento.fecha' => 'occurred_at',
        'evento.detalle' => 'description'
      },
      response_value_mapper: { 'EnDistribucion' => 'in_transit', 'Entregado' => 'delivered' }
    )
  end

  let(:payload) do
    {
      'envio' => { 'numeroDeEnvio' => 'AND-123' },
      'evento' => {
        'estado' => 'EnDistribucion',
        'fecha' => '2026-08-20T10:00:00Z',
        'detalle' => 'Salió a reparto'
      }
    }
  end

  it 'extracts the four raw fields from a nested payload', :aggregate_failures do
    expect(result[:tracking_number]).to eq('AND-123')
    expect(result[:external_status]).to eq('EnDistribucion')
    expect(result[:description]).to eq('Salió a reparto')
    expect(result[:occurred_at]).to eq(Time.zone.parse('2026-08-20T10:00:00Z'))
  end

  it 'keeps the raw external_status while also returning the translated internal_status',
     :aggregate_failures do
    # Este es EL test de la card: ParseExternalResponse solo, usado derecho, hubiera pisado
    # el estado crudo con el traducido. Acá tienen que convivir los dos en el mismo resultado.
    expect(result[:external_status]).to eq('EnDistribucion')
    expect(result[:internal_status]).to eq('in_transit')
  end

  context 'when the external status is not mapped by the template' do
    let(:payload) { { 'evento' => { 'estado' => 'EstadoDesconocido' } } }

    it 'returns the raw external_status and a nil internal_status', :aggregate_failures do
      expect(result[:external_status]).to eq('EstadoDesconocido')
      expect(result[:internal_status]).to be_nil
    end
  end

  context 'when the mapped value is not one of Shipment::STATUSES' do
    let(:service) do
      Service.create!(
        service_name: 'Correo Ficticio',
        type: 'courier',
        uri: 'https://api.correoficticio.com',
        http_method: 'POST',
        response_mapper: { 'evento.estado' => 'external_status' },
        response_value_mapper: { 'Perdido' => 'lost_in_transit' }
      )
    end
    let(:payload) { { 'evento' => { 'estado' => 'Perdido' } } }

    it 'returns a nil internal_status' do
      expect(result[:internal_status]).to be_nil
    end
  end

  describe 'occurred_at normalization' do
    let(:service) do
      Service.create!(
        service_name: 'Andreani',
        type: 'courier',
        uri: 'https://api.andreani.com',
        http_method: 'POST',
        response_mapper: { 'evento.fecha' => 'occurred_at' },
        response_value_mapper: {}
      )
    end

    it 'parses an ISO8601 timestamp' do
      payload = { 'evento' => { 'fecha' => '2026-08-20T10:00:00Z' } }
      result = described_class.new(service: service, payload: payload).call
      expect(result[:occurred_at]).to eq(Time.zone.parse('2026-08-20T10:00:00Z'))
    end

    it 'parses a numeric epoch' do
      payload = { 'evento' => { 'fecha' => 1_755_684_000 } }
      result = described_class.new(service: service, payload: payload).call
      expect(result[:occurred_at]).to eq(Time.zone.at(1_755_684_000))
    end

    it 'returns nil for a garbage date instead of raising' do
      payload = { 'evento' => { 'fecha' => 'no-es-una-fecha-valida' } }
      result = described_class.new(service: service, payload: payload).call
      expect(result[:occurred_at]).to be_nil
    end

    it 'returns nil when occurred_at is absent from the payload' do
      result = described_class.new(service: service, payload: {}).call
      expect(result[:occurred_at]).to be_nil
    end
  end

  context 'when the template does not map a key' do
    let(:service) do
      Service.create!(
        service_name: 'Andreani',
        type: 'courier',
        uri: 'https://api.andreani.com',
        http_method: 'POST',
        response_mapper: { 'evento.estado' => 'external_status' },
        response_value_mapper: {}
      )
    end
    let(:payload) { { 'evento' => { 'estado' => 'Entregado' } } }

    it 'returns nil for the unmapped keys without raising', :aggregate_failures do
      expect(result[:tracking_number]).to be_nil
      expect(result[:description]).to be_nil
      expect(result[:occurred_at]).to be_nil
    end
  end

  context 'when the response_mapper uses an array-indexed path' do
    let(:service) do
      Service.create!(
        service_name: 'Andreani',
        type: 'courier',
        uri: 'https://api.andreani.com',
        http_method: 'POST',
        response_mapper: { 'bulto.0.numeroDeEnvio' => 'tracking_number' },
        response_value_mapper: {}
      )
    end
    let(:payload) { { 'bulto' => [{ 'numeroDeEnvio' => 'AND-999' }] } }

    it 'follows the index into the array' do
      expect(result[:tracking_number]).to eq('AND-999')
    end
  end

  # Una ruta con el marcador de colección describe una lista (p.ej. ítems de una orden), no
  # un evento suelto de tracking: si el mapper sólo tiene una entrada así para esta clave,
  # tiene que ignorarse en vez de usarse (y no romper intentando navegarla).
  context 'when the response_mapper entry is marked as a collection ([])' do
    let(:service) do
      Service.create!(
        service_name: 'Andreani',
        type: 'courier',
        uri: 'https://api.andreani.com',
        http_method: 'POST',
        response_mapper: {
          "items#{Integrations::ParseExternalResponse::COLLECTION_MARKER}.estado" => 'tracking_number'
        },
        response_value_mapper: {}
      )
    end
    let(:payload) { { 'items' => [{ 'estado' => 'no-deberia-usarse' }] } }

    it 'ignores the entry instead of navigating it' do
      expect(result[:tracking_number]).to be_nil
    end
  end
end
