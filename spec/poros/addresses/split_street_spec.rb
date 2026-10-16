# frozen_string_literal: true

require 'rails_helper'

# TESIS-185: hay couriers que piden la calle y la altura en campos separados, y
# el sistema guarda la dirección en una sola línea.
RSpec.describe Addresses::SplitStreet, type: :poro do
  def parts(address) = described_class.call(address)

  describe 'a street with its number at the end' do
    it 'separates the street from the number' do
      expect(parts('Av. Corrientes 1234'))
        .to eq(street: 'Av. Corrientes', number: '1234', unit: nil)
    end

    it 'keeps the numbers that are part of the name of the street' do
      expect(parts('Avenida 25 de Mayo 1234'))
        .to include(street: 'Avenida 25 de Mayo', number: '1234')
    end

    it 'takes the last number when the street is itself a number' do
      expect(parts('Calle 7 1234')).to include(street: 'Calle 7', number: '1234')
    end

    it 'tolerates extra spaces' do
      expect(parts('  San Martín    456 ')).to include(street: 'San Martín', number: '456')
    end
  end

  describe 'a number announced with a mark' do
    {
      'Calle 7 N° 1234' => ['Calle 7', '1234'],
      'Diagonal 73 Nº 1500' => ['Diagonal 73', '1500'],
      'Mitre Nro. 55' => %w[Mitre 55],
      'Mitre nro 55' => %w[Mitre 55],
      'Belgrano número 300' => %w[Belgrano 300],
      'Corrientes # 900' => %w[Corrientes 900]
    }.each do |address, (street, number)|
      it "reads #{address.inspect} as #{street.inspect} and #{number.inspect}" do
        expect(parts(address)).to include(street: street, number: number)
      end
    end
  end

  describe 'the unit inside the building' do
    it 'keeps floor and apartment apart from the number' do
      expect(parts('Belgrano 123 piso 4 dto B'))
        .to eq(street: 'Belgrano', number: '123', unit: 'piso 4 dto B')
    end

    it 'understands a bare floor with a degree sign' do
      expect(parts('Calle 7 1234 4° B')).to eq(street: 'Calle 7', number: '1234', unit: '4° B')
    end

    it 'keeps the unit after a marked number' do
      expect(parts('Mitre Nro. 55 of. 3')).to include(number: '55', unit: 'of. 3')
    end

    it 'reads the ground floor', :aggregate_failures do
      expect(parts('Av. Corrientes 1234 PB')).to include(number: '1234', unit: 'PB')
      expect(parts('Lavalle 100 dpto 2')).to include(number: '100', unit: 'dpto 2')
    end

    it 'takes the unit from after the comma' do
      expect(parts('Rivadavia 1234, 3° A, CABA'))
        .to eq(street: 'Rivadavia', number: '1234', unit: '3° A')
    end
  end

  describe 'what comes after the comma' do
    # La localidad la recibe el courier en su propio campo.
    it 'leaves the locality out' do
      expect(parts('Av. 7 N° 1234, La Plata'))
        .to eq(street: 'Av. 7', number: '1234', unit: nil)
    end

    it 'does not take a locality that starts like a unit for one' do
      expect(parts('Mitre 55, Localidad X')).to include(unit: nil)
    end
  end

  describe 'an address without a number' do
    {
      'San Martín S/N' => 'San Martín',
      'San Martín s/n°' => 'San Martín',
      'Ruta 3 sin número' => 'Ruta 3',
      'Ruta 3 sin numero' => 'Ruta 3',
      'Ruta 3 sin nro' => 'Ruta 3'
    }.each do |address, street|
      it "reads #{address.inspect} as having no number" do
        expect(parts(address)).to include(street: street, number: nil)
      end
    end

    it 'keeps a unit that comes after the S/N' do
      expect(parts('San Martín S/N lote 5')).to include(number: nil, unit: 'lote 5')
    end

    # Inventar una altura manda el paquete a otra puerta: sin una clara, la
    # calle es el texto entero.
    it 'gives back the whole text as the street when there is no number' do
      expect(parts('Pasaje Roma')).to eq(street: 'Pasaje Roma', number: nil, unit: nil)
    end

    it 'does not take the number of a numbered street as its door', :aggregate_failures do
      expect(parts('Calle 7')).to eq(street: 'Calle 7', number: nil, unit: nil)
      expect(parts('Av. 60')).to include(street: 'Av. 60', number: nil)
      expect(parts('Diagonal 73')).to include(street: 'Diagonal 73', number: nil)
    end

    it 'does not read a kilometer of a route as a door' do
      expect(parts('Ruta 8 km 65')).to eq(street: 'Ruta 8 km 65', number: nil, unit: nil)
    end
  end

  describe 'an empty address' do
    it 'answers everything as nil', :aggregate_failures do
      expect(parts(nil)).to eq(street: nil, number: nil, unit: nil)
      expect(parts('')).to eq(street: nil, number: nil, unit: nil)
      expect(parts('  ,  ')).to eq(street: nil, number: nil, unit: nil)
    end
  end
end
