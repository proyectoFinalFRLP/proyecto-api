# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Integrations::ParseExternalResponse, type: :poro do
  let(:service) do
    Service.create!(service_name: 'Andreani', type: 'courier', uri: 'https://api.andreani.com',
                    http_method: 'POST',
                    response_mapper: { 'bulto.0.numeroDeEnvio' => 'tracking_number',
                                       'estado' => 'status' },
                    response_value_mapper: { 'Entregado' => 'delivered' })
  end

  it 'flattens nested fields according to the response_mapper' do
    body = { 'bulto' => [{ 'numeroDeEnvio' => 'AND-123' }] }
    result = described_class.new(service: service, response_body: body).call
    expect(result).to eq('tracking_number' => 'AND-123')
  end

  it 'translates values through the response_value_mapper' do
    result = described_class.new(service: service, response_body: { 'estado' => 'Entregado' }).call
    expect(result['status']).to eq('delivered')
  end

  it 'leaves values without translation untouched' do
    result = described_class.new(service: service, response_body: { 'estado' => 'Otro' }).call
    expect(result['status']).to eq('Otro')
  end

  it 'skips paths that are missing in the external response' do
    result = described_class.new(service: service, response_body: { 'estado' => 'Entregado' }).call
    expect(result).not_to have_key('tracking_number')
  end

  it 'ignores external fields that are not in the mapper' do
    result = described_class.new(service: service, response_body: { 'extra' => 'dato' }).call
    expect(result).to eq({})
  end

  # Las entradas con `[]` describen una lista y las resuelve
  # ParseExternalCollection: acá tienen que pasar de largo sin ensuciar el hash.
  it 'ignores the collection entries of the mapper' do
    service.update!(response_mapper: { 'items[].sku' => 'external_product_id' })
    body = { 'items' => [{ 'sku' => 'A-1' }] }

    expect(described_class.new(service: service, response_body: body).call).to eq({})
  end

  it 'translates with a mapper given by the caller instead of the template one' do
    result = described_class.new(service: service, response_body: { 'sku' => 'A-1' },
                                 mapper: { 'sku' => 'external_product_id' }).call

    expect(result).to eq('external_product_id' => 'A-1')
  end
end
