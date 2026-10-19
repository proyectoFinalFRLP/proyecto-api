# frozen_string_literal: true

require 'rails_helper'

# TESIS-185: el bulto único con el que se cotiza, estimado a partir de las
# medidas de lo que lleva.
RSpec.describe Shipments::ConsolidatedPackage, type: :poro do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }

  def product(sku, length = nil, width = nil, height = nil)
    Product.create!(company: company, sku: sku, name: sku,
                    length_cm: length, width_cm: width, height_cm: height)
  end

  def package(*lines) = described_class.call(lines)

  it 'sums length × width × height × quantity of each line', :aggregate_failures do
    box = package([product('A', 10, 10, 10), 2], [product('B', 20, 5, 1), 3])

    expect(box[:volume_cm3]).to eq(2300.0)
    expect(box[:volume_m3]).to eq(0.0023)
  end

  it 'makes a cube with that volume' do
    expect(package([product('A', 10, 10, 10), 8])[:side_cm]).to eq(20.0)
  end

  # El cubo nunca puede quedar más chico que lo que lleva.
  it 'rounds the side up to the hundredth', :aggregate_failures do
    side = package([product('A', 10, 10, 10), 2])[:side_cm]

    expect(side).to eq(12.6)
    expect(side**3).to be >= 2000
  end

  it 'does not round up an exact cube because of the floating point' do
    expect(package([product('A', 10, 10, 10), 1])[:side_cm]).to eq(10.0)
  end

  # Sumarlo como cero cotizaba una caja más chica que lo que lleva.
  it 'does not estimate the package when a product lacks a measure' do
    box = package([product('A', 10, 10, 10), 1], [product('B', 30, 30), 5])

    expect(box).to eq(side_cm: nil, volume_cm3: nil, volume_m3: nil)
  end

  # Cero sería una caja vacía: nil dice que no se sabe.
  it 'answers nil when nothing has measures' do
    expect(package([product('A'), 3])).to eq(side_cm: nil, volume_cm3: nil, volume_m3: nil)
  end

  it 'answers nil for no lines at all' do
    expect(package).to eq(side_cm: nil, volume_cm3: nil, volume_m3: nil)
  end

  it 'answers numbers, not decimals that would travel as text', :aggregate_failures do
    box = package([product('A', 16.5, 7.8, 0.9), 1])

    expect(box.values).to all(be_a(Float))
  end
end
