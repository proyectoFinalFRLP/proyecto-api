# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Catalog::DeductStock, type: :poro do
  subject(:deduct) { described_class.new(product: product, quantity: quantity) }

  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:product) { Product.create!(company: company, sku: 'SKU-001', name: 'Celular') }
  let(:quantity) { 3 }

  def warehouse(name, zip)
    Warehouse.create!(company: company, name: name, zip_code: zip, address: "#{name} 1")
  end

  def create_stock(quantity:, name: 'W', zip: '1900')
    Stock.create!(product: product, warehouse: warehouse(name, zip), quantity: quantity)
  end

  def deduct_with(wh_id, qty)
    described_class.new(product: product, quantity: qty, warehouse_id: wh_id).call
  end

  before { Current.company_id = company.id }

  context 'when a single warehouse holds the stock' do
    let!(:stock) { Stock.create!(product: product, warehouse: warehouse('Central', '1900'), quantity: 10) }

    it 'deducts the exact quantity sold' do
      expect { deduct.call }.to change { stock.reload.quantity }.from(10).to(7)
    end

    it 'returns the stock row it touched' do
      expect(deduct.call).to eq(stock)
    end

    it 'empties the warehouse when the sale takes everything' do
      described_class.new(product: product, quantity: 10).call
      expect(stock.reload.quantity).to eq(0)
    end
  end

  context 'when several warehouses hold stock' do
    let!(:first) { Stock.create!(product: product, warehouse: warehouse('Central', '1900'), quantity: 5) }
    let!(:second) { Stock.create!(product: product, warehouse: warehouse('Norte', '1602'), quantity: 8) }

    it 'takes the whole sale from the first warehouse that can cover it' do
      deduct.call
      expect([first.reload.quantity, second.reload.quantity]).to eq([2, 8])
    end

    context 'when the first warehouse cannot cover the sale by itself' do
      let(:quantity) { 6 }

      it 'skips it and uses the next one that can' do
        deduct.call
        expect([first.reload.quantity, second.reload.quantity]).to eq([5, 2])
      end
    end

    context 'when no single warehouse can cover the sale' do
      let(:quantity) { 12 }

      it 'raises instead of splitting the deduction (MVP rule, ADR-010)' do
        expect { deduct.call }.to raise_error(Catalog::InsufficientStockError, /insufficient stock/)
      end

      it 'leaves every warehouse untouched' do
        expect { suppress(Catalog::InsufficientStockError) { deduct.call } }
          .not_to(change { [first.reload.quantity, second.reload.quantity] })
      end
    end
  end

  context 'when the product has no stock at all' do
    it 'raises InsufficientStockError naming the product' do
      expect { deduct.call }.to raise_error(Catalog::InsufficientStockError, /SKU-001/)
    end

    it 'exposes the product and the quantity for the caller' do
      expect { deduct.call }.to raise_error(
        having_attributes(class: Catalog::InsufficientStockError,
                          product_id: product.id, quantity: 3)
      )
    end
  end

  context 'when the quantity is not positive' do
    let(:quantity) { 0 }

    it 'refuses to run instead of writing a no-op' do
      expect { deduct.call }.to raise_error(ArgumentError, /positive/)
    end
  end

  it 'serializes the deduction with the stock advisory lock (ADR-009)' do
    Stock.create!(product: product, warehouse: warehouse('Central', '1900'), quantity: 10)
    allow(Catalog::WithStockLock).to receive(:new).and_call_original

    deduct.call

    expect(Catalog::WithStockLock).to have_received(:new).with(product_id: product.id, wait: true)
  end

  it 'forwards wait: to WithStockLock (ADR-009)' do
    Stock.create!(product: product, warehouse: warehouse('Central', '1900'), quantity: 10)
    allow(Catalog::WithStockLock).to receive(:new).and_call_original

    described_class.new(product: product, quantity: 3, wait: false).call

    expect(Catalog::WithStockLock).to have_received(:new).with(product_id: product.id, wait: false)
  end

  # TESIS-42: warehouse_id explícito para ventas offline
  context 'with explicit warehouse_id' do
    it 'deducts from the specified warehouse' do
      north = create_stock(quantity: 10, name: 'Norte', zip: '1602')
      described_class.new(product: product, quantity: 3, warehouse_id: north.warehouse_id).call
      expect(north.reload.quantity).to eq(7)
    end

    it 'raises when the specified warehouse has insufficient stock' do
      stock = create_stock(quantity: 3)
      expect do
        described_class.new(product: product, quantity: 5, warehouse_id: stock.warehouse_id).call
      end.to raise_error(Catalog::InsufficientStockError)
    end

    it 'ignores other warehouses even if they could cover the sale' do
      low = create_stock(quantity: 3)
      high = create_stock(quantity: 10, name: 'Norte')
      suppress(Catalog::InsufficientStockError) { deduct_with(low.warehouse_id, 5) }
      expect(high.reload.quantity).to eq(10)
    end
  end
end
