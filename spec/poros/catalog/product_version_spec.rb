# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Catalog::ProductVersion, type: :poro do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:product) { Product.create!(company: company, sku: 'SKU-1', name: 'Widget', weight: 2) }
  let(:central) do
    Warehouse.create!(company: company, name: 'Central', zip_code: '1900', address: 'A')
  end
  let(:north) do
    Warehouse.create!(company: company, name: 'North', zip_code: '1901', address: 'B')
  end

  # Metodo y no `subject`: RSpec memoiza el subject, y estos ejemplos necesitan
  # leer la version dos veces con un cambio en el medio.
  def version
    described_class.new(product: product.reload).call
  end

  it 'is stable when nothing changes' do
    expect(version).to eq(described_class.new(product: product.reload).call)
  end

  it 'changes when an edited field changes' do
    before_change = version
    product.update!(name: 'Renamed')

    expect(version).not_to eq(before_change)
  end

  # El caso que motiva la card: el modal guarda cantidades absolutas, asi que un
  # movimiento de stock ajeno tiene que invalidar lo que el usuario vio.
  it 'changes when the stock of a warehouse moves' do
    stock = Stock.create!(product: product, warehouse: central, quantity: 10)
    before_change = version
    stock.update!(quantity: 5)

    expect(version).not_to eq(before_change)
  end

  it 'changes when a warehouse is added' do
    Stock.create!(product: product, warehouse: central, quantity: 10)
    before_change = version
    Stock.create!(product: product, warehouse: north, quantity: 3)

    expect(version).not_to eq(before_change)
  end

  # Sin ordenar, la misma fila daria huellas distintas segun como Postgres
  # devuelva los stocks, y el guardado fallaria al azar.
  it 'does not depend on the order the stocks come back in' do
    Stock.create!(product: product, warehouse: north, quantity: 3)
    Stock.create!(product: product, warehouse: central, quantity: 10)
    reversed = Product.find(product.id)
    allow(reversed).to receive(:stocks).and_return(reversed.stocks.to_a.reverse)

    expect(described_class.new(product: reversed).call).to eq(version)
  end

  it 'is not affected by fields the modal does not edit' do
    before_change = version
    product.update_column(:sku, 'SKU-CHANGED') # rubocop:disable Rails/SkipsModelValidations

    expect(version).to eq(before_change)
  end
end
