# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Catalog::DispatchTransfer, type: :poro do
  subject(:dispatch) do
    described_class.new(company: company, product: product, origin_warehouse: origin,
                        destination_warehouse: destination, quantity: quantity)
  end

  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:product) { Product.create!(company: company, sku: 'SKU-1', name: 'Widget') }
  let(:origin) { Warehouse.create!(company: company, name: 'Central', zip_code: '1900', address: 'A') }
  let(:destination) { Warehouse.create!(company: company, name: 'North', zip_code: '1901', address: 'B') }
  let(:quantity) { 4 }

  before { Stock.create!(product: product, warehouse: origin, quantity: 10) }

  def origin_quantity = Stock.find_by(product: product, warehouse: origin).quantity

  it 'leaves the transfer in flight' do
    expect(dispatch.call).to be_in_transit
  end

  it 'deducts the units from the origin warehouse' do
    dispatch.call
    expect(origin_quantity).to eq(6)
  end

  it 'does not put the units in the destination yet' do
    dispatch.call
    expect(Stock.find_by(product: product, warehouse: destination)).to be_nil
  end

  it 'keeps the units out of total_stock while they travel' do
    dispatch.call
    expect(product.reload.total_stock).to eq(6)
  end

  it 'reports them as in transit' do
    dispatch.call
    expect(product.reload.in_transit_quantity).to eq(4)
  end

  context 'when the origin does not hold enough units' do
    let(:quantity) { 99 }

    it 'raises instead of leaving a negative balance' do
      expect { dispatch.call }.to raise_error(Catalog::InsufficientWarehouseStockError)
    end

    context 'when the dispatch has already failed' do
      before { suppress(Catalog::InsufficientWarehouseStockError) { dispatch.call } }

      it 'writes no transfer at all' do
        expect(StockTransfer.count).to eq(0)
      end

      it 'leaves the origin balance untouched' do
        expect(origin_quantity).to eq(10)
      end
    end
  end
end
