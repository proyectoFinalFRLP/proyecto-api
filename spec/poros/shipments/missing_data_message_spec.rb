# frozen_string_literal: true

require 'rails_helper'

# El motivo que ve el operador cuando la plantilla del courier exige un dato que
# el envío no tiene (TESIS-188): en castellano y con el producto a corregir.
RSpec.describe Shipments::MissingDataMessage do
  let(:phone) { Product.new(name: 'Celular', weight: 0.2, length_cm: 15, width_cm: 7, height_cm: 1) }
  let(:box) { Product.new(name: 'Caja', weight: 0, length_cm: nil, width_cm: 20, height_cm: nil) }

  def message(key, products = [phone, box], payload: {})
    described_class.call(courier: 'OCA', key: key, products: products, payload: payload)
  end

  it 'names the products without weight' do
    expect(message('package_weight_kg')).to eq('Para despachar con OCA falta el peso de “Caja”.')
  end

  it 'names the missing measures of each product, whatever package key the template asked for' do
    expect(message('package_height_cm'))
      .to eq('Para despachar con OCA faltan el largo y el alto de “Caja”.')
  end

  it 'says a single missing measure in singular' do
    expect(message('package_length_cm', [phone, Product.new(name: 'Funda', length_cm: nil, width_cm: 9, height_cm: 1)]))
      .to eq('Para despachar con OCA falta el largo de “Funda”.')
  end

  it 'falls back to the products when none is missing the data' do
    expect(message('package_volume_m3', [phone])).to eq('Para despachar con OCA faltan las medidas de los productos.')
  end

  it 'translates the address data of each end of the trip' do
    expect(message('destination_postal_code')).to eq('Para despachar con OCA falta el código postal del destino.')
  end

  it 'says the postal code is invalid, not missing, when one is loaded' do
    expect(message('destination_postal_code', payload: { 'destination_zip_code' => '14' }))
      .to eq('Para despachar con OCA, el código postal del destino («14») no es válido.')
  end

  it 'translates the street number of the origin' do
    expect(message('origin_street_number'))
      .to eq('Para despachar con OCA falta la altura de la calle del depósito de origen.')
  end

  it 'still says something for a key it does not know' do
    expect(message('nrocuenta')).to eq('Para despachar con OCA falta un dato del envío (nrocuenta).')
  end
end
