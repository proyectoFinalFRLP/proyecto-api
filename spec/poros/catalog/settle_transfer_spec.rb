# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Catalog::SettleTransfer, type: :poro do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:product) { Product.create!(company: company, sku: 'SKU-1', name: 'Widget') }
  let(:origin) { Warehouse.create!(company: company, name: 'Central', zip_code: '1900', address: 'A') }
  let(:destination) { Warehouse.create!(company: company, name: 'North', zip_code: '1901', address: 'B') }

  let(:transfer) do
    Stock.create!(product: product, warehouse: origin, quantity: 10)
    Catalog::DispatchTransfer.new(company: company, product: product, origin_warehouse: origin,
                                  destination_warehouse: destination, quantity: 4).call
  end

  def quantity_in(warehouse)
    Stock.find_by(product: product, warehouse: warehouse)&.quantity || 0
  end

  describe 'receiving' do
    before { described_class.new(transfer: transfer, outcome: :received).call }

    it 'marks the transfer as received' do
      expect(transfer.reload).to be_received
    end

    it 'adds the units to the destination' do
      expect(quantity_in(destination)).to eq(4)
    end

    it 'does not give them back to the origin' do
      expect(quantity_in(origin)).to eq(6)
    end

    it 'stops counting them as in transit' do
      expect(product.reload.in_transit_quantity).to eq(0)
    end

    it 'returns them to total_stock' do
      expect(product.reload.total_stock).to eq(10)
    end

    it 'stamps when it was settled' do
      expect(transfer.reload.settled_at).to be_present
    end
  end

  describe 'cancelling' do
    before { described_class.new(transfer: transfer, outcome: :cancelled).call }

    it 'marks the transfer as cancelled' do
      expect(transfer.reload).to be_cancelled
    end

    it 'gives the units back to the origin' do
      expect(quantity_in(origin)).to eq(10)
    end

    it 'leaves nothing in the destination' do
      expect(quantity_in(destination)).to eq(0)
    end
  end

  # Sin este corte, dos requests simultáneos sobre la misma transferencia
  # sumarían las unidades al destino dos veces.
  it 'refuses to settle a transfer that is no longer in flight' do
    described_class.new(transfer: transfer, outcome: :received).call

    expect { described_class.new(transfer: transfer, outcome: :cancelled).call }
      .to raise_error(described_class::NotInFlightError)
  end

  it 'does not move stock twice when settled again' do
    described_class.new(transfer: transfer, outcome: :received).call
    suppress(described_class::NotInFlightError) do
      described_class.new(transfer: transfer, outcome: :received).call
    end

    expect(quantity_in(destination)).to eq(4)
  end

  it 'rejects an unknown outcome' do
    expect { described_class.new(transfer: transfer, outcome: :lost).call }
      .to raise_error(ArgumentError)
  end
end
