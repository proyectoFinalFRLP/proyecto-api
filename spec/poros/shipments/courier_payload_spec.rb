# frozen_string_literal: true

require 'rails_helper'

# TESIS-185: el vocabulario que las plantillas de courier mapean, compartido
# por la cotización y el despacho.
RSpec.describe Shipments::CourierPayload, type: :poro do
  subject(:payload) do
    described_class.call(origin: origin, destination: destination, lines: lines,
                         declared_value: BigDecimal('15999.90'))
  end

  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:origin) do
    Warehouse.create!(company: company, name: 'Central', zip_code: 'B1900ABC',
                      address: 'Av. 7 N° 1234, La Plata', city: 'La Plata',
                      province: 'Buenos Aires')
  end
  let(:destination) do
    { zip_code: 'C1414ABC', address: 'Av. Corrientes 1234 piso 4', city: 'CABA',
      province: 'Ciudad Autónoma de Buenos Aires' }
  end
  let(:lines) do
    sensor = Product.create!(company: company, sku: 'S-1', name: 'Sensor', weight: 0.5,
                             length_cm: 10, width_cm: 10, height_cm: 10)
    [[sensor, 8]]
  end

  # Las plantillas sembradas de Andreani y Correo las mapean: no pueden
  # cambiar de nombre ni de contenido.
  it 'keeps the keys the existing templates map, as they were' do
    expect(payload).to include('origin_zip_code' => 'B1900ABC', 'destination_zip_code' => 'C1414ABC',
                               'origin_address' => origin.address,
                               'destination_address' => destination[:address],
                               'total_weight' => BigDecimal(4), 'total_items' => 8)
  end

  it 'breaks the origin down into its parts' do
    expect(payload).to include('origin_street' => 'Av. 7', 'origin_street_number' => '1234',
                               'origin_postal_code' => '1900', 'origin_city' => 'La Plata',
                               'origin_province' => 'Buenos Aires')
  end

  it 'breaks the destination down into its parts' do
    expect(payload).to include('destination_street' => 'Av. Corrientes',
                               'destination_street_number' => '1234',
                               'destination_postal_code' => '1414',
                               'destination_city' => 'CABA',
                               'destination_province' => 'Ciudad Autónoma de Buenos Aires')
  end

  it 'describes a single consolidated package' do
    expect(payload).to include('package_length_cm' => 20.0, 'package_width_cm' => 20.0,
                               'package_height_cm' => 20.0, 'package_volume_cm3' => 8000.0,
                               'package_volume_m3' => 0.008)
  end

  it 'declares the value it was given, as a number' do
    expect(payload['declared_value']).to eq(15_999.9)
  end

  # Un dato que no está viaja en nil: la clave existe para cualquier plantilla.
  context 'when the data is not there' do
    subject(:payload) do
      described_class.call(origin: bare_origin, destination: { zip_code: '5000' },
                           lines: [[Product.create!(company: company, sku: 'X', name: 'X'), 1]])
    end

    let(:bare_origin) do
      Warehouse.create!(company: company, name: 'Sur', zip_code: '8000', address: 'Calle 1')
    end

    it 'sends every key of the vocabulary anyway, in nil' do
      expect(payload.values_at('origin_city', 'origin_province', 'origin_street_number',
                               'destination_address', 'destination_street', 'destination_city',
                               'package_length_cm', 'package_volume_m3', 'declared_value'))
        .to all(be_nil)
    end

    it 'still shortens the postal codes it has' do
      expect(payload.values_at('origin_postal_code', 'destination_postal_code'))
        .to eq(%w[8000 5000])
    end
  end
end
