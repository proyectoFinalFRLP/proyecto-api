# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Product, type: :model do
  subject(:product) do
    described_class.new(company: company, sku: 'SKU-001', name: 'Widget Alpha')
  end

  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }

  it 'is valid with required attributes' do
    expect(product).to be_valid
  end

  it 'defaults weight to 0.0' do
    product.save!
    expect(product.weight).to eq(0.0)
  end

  it 'is invalid without a company' do
    product.company = nil
    expect(product).not_to be_valid
  end

  describe 'category' do
    it 'is valid without one' do
      product.category = nil
      expect(product).to be_valid
    end

    it 'accepts every value of the vocabulary' do
      Product::CATEGORIES.each do |category|
        product.category = category
        expect(product).to be_valid, "expected #{category} to be valid"
      end
    end

    it 'rejects a value outside the vocabulary', :aggregate_failures do
      product.category = 'Groceries'
      expect(product).not_to be_valid
      expect(product.errors[:category]).to include('is not included in the list')
    end
  end

  describe '.stock_status_for' do
    it 'maps a quantity to the three availability states', :aggregate_failures do
      expect(described_class.stock_status_for(0)).to eq('out_of_stock')
      expect(described_class.stock_status_for(1)).to eq('low')
      expect(described_class.stock_status_for(Product::LOW_STOCK_THRESHOLD)).to eq('low')
      expect(described_class.stock_status_for(Product::LOW_STOCK_THRESHOLD + 1)).to eq('available')
    end

    it 'treats a missing quantity as no units' do
      expect(described_class.stock_status_for(nil)).to eq('out_of_stock')
    end

    it 'only answers values of the vocabulary' do
      results = [0, 1, 1_000].map { |quantity| described_class.stock_status_for(quantity) }

      expect(results).to all(be_in(Product::STOCK_STATUSES))
    end
  end

  describe '#primary_stock' do
    let(:central) do
      Warehouse.create!(company: company, name: 'Central', zip_code: '1900', address: 'Calle 1')
    end
    let(:north) do
      Warehouse.create!(company: company, name: 'North', zip_code: '1901', address: 'Calle 2')
    end

    before { product.save! }

    it 'is nil when the product has no stock rows' do
      expect(product.primary_stock).to be_nil
    end

    it 'returns the warehouse holding the most units' do
      Stock.create!(product: product, warehouse: central, quantity: 3)
      Stock.create!(product: product, warehouse: north, quantity: 9)

      expect(product.reload.primary_stock.warehouse_id).to eq(north.id)
    end

    it 'breaks ties by the lowest warehouse id' do
      Stock.create!(product: product, warehouse: north, quantity: 7)
      Stock.create!(product: product, warehouse: central, quantity: 7)

      expect(product.reload.primary_stock.warehouse_id).to eq([central.id, north.id].min)
    end

    it 'ignores rows holding zero units' do
      Stock.create!(product: product, warehouse: central, quantity: 0)
      Stock.create!(product: product, warehouse: north, quantity: 4)

      expect(product.reload.primary_stock.warehouse_id).to eq(north.id)
    end

    it 'is nil when every row holds zero units' do
      Stock.create!(product: product, warehouse: central, quantity: 0)

      expect(product.reload.primary_stock).to be_nil
    end
  end

  # TESIS-162: el stock se descuenta al CREAR la orden y el despacho no vuelve a
  # tocar `stocks`, así que lo vendido y no despachado sigue en el estante
  # aunque ya no figure en ninguna fila de stock.
  describe 'the units already sold that did not leave yet' do
    let(:central) do
      Warehouse.create!(company: company, name: 'Central', zip_code: '1900', address: 'Calle 1')
    end
    let(:north) do
      Warehouse.create!(company: company, name: 'North', zip_code: '1901', address: 'Calle 2')
    end

    before do
      product.save!
      Stock.create!(product: product, warehouse: central, quantity: 10)
    end

    def sell(quantity, warehouse: central, status: 'paid', shipment_status: nil, ships: true)
      order = Order.create!(company: company, customer_name: 'Cliente', status: status,
                            requires_shipping: ships)
      OrderItem.create!(order: order, product: product, warehouse: warehouse,
                        quantity: quantity, unit_price: 100)
      ship(order, shipment_status) unless shipment_status.nil?
      order
    end

    def ship(order, status)
      Shipment.create!(company: company, order: order, status: status,
                       tracking_number: status == 'pending' ? nil : 'AND-1')
    end

    it 'counts a sale that has no shipment yet' do
      sell(3)

      expect(product.committed_quantity).to eq(3)
    end

    it 'counts a sale whose shipment was opened but not dispatched' do
      sell(2, shipment_status: 'pending')

      expect(product.committed_quantity).to eq(2)
    end

    # Ya salió del depósito: deja de estar comprometida porque deja de estar.
    it 'stops counting it once the shipment was dispatched' do
      sell(4, shipment_status: 'ready_to_ship')

      expect(product.committed_quantity).to be_zero
    end

    it 'ignores a cancelled order' do
      sell(5, status: 'cancelled')

      expect(product.committed_quantity).to be_zero
    end

    # Un retiro no tiene envío —`CreateShipment` lo rechaza— y `Order` no tiene
    # un estado «retirada»: contarlo lo dejaría comprometido para siempre y el
    # «En depósito» crecería con cada venta de mostrador. En el mostrador
    # registrar la venta y entregarla son el mismo momento.
    it 'ignores an order the customer picks up at the store' do
      sell(6, ships: false)

      expect(product.committed_quantity).to be_zero
    end

    it 'leaves a pickup out of the breakdown by warehouse too' do
      sell(6, ships: false)

      expect(product.committed_by_warehouse).to be_empty
    end

    it 'still counts the sales that do ship, alongside a pickup' do
      sell(6, ships: false) && sell(2)

      expect(product.committed_quantity).to eq(2)
    end

    # Las anteriores a TESIS-126 no saben de qué depósito salieron: contarlas en
    # el total pero en ningún depósito dejaría filas que no suman el encabezado.
    it 'leaves out a line that does not record its warehouse' do
      order = Order.create!(company: company, customer_name: 'Cliente', status: 'paid')
      OrderItem.create!(order: order, product: product, quantity: 7, unit_price: 100)

      expect(product.committed_quantity).to be_zero
    end

    it 'breaks it down by warehouse, with the name of each one' do
      sell(3) && sell(1, warehouse: north)

      expect(product.committed_by_warehouse).to eq(
        [{ warehouse_id: central.id, name: 'Central', quantity: 3 },
         { warehouse_id: north.id, name: 'North', quantity: 1 }]
      )
    end

    # El encabezado del detalle muestra estos tres, y tienen que cerrar entre sí.
    describe 'the three figures of the detail' do
      before { sell(3) }

      it 'promises what is free' do
        expect(product.available_to_promise).to eq(10)
      end

      it 'commits what was sold' do
        expect(product.committed_quantity).to eq(3)
      end

      it 'holds both on the shelf' do
        expect(product.on_hand_quantity).to eq(13)
      end
    end

    it 'promises zero and not nil for a product nobody reserved', :aggregate_failures do
      expect(product.committed_quantity).to eq(0)
      expect(product.committed_by_warehouse).to eq([])
    end
  end

  %i[sku name].each do |attribute|
    it "is invalid without #{attribute}" do
      product.public_send("#{attribute}=", nil)
      expect(product).not_to be_valid
    end
  end

  it 'enforces SKU uniqueness scoped to company' do
    product.save!
    duplicate = described_class.new(company: company, sku: 'SKU-001', name: 'Widget Beta')
    expect(duplicate).not_to be_valid
  end

  it 'allows the same SKU across different companies' do
    product.save!
    other_company = Company.create!(name: 'Other', tax_id: '30-12345678-9')
    other_product = described_class.new(company: other_company, sku: 'SKU-001', name: 'Widget Beta')
    expect(other_product).to be_valid
  end

  it 'validates weight is not negative' do
    product.weight = -1
    expect(product).not_to be_valid
  end

  it 'belongs to a company' do
    expect(described_class.reflect_on_association(:company).macro).to eq(:belongs_to)
  end

  it 'has many stocks' do
    expect(described_class.reflect_on_association(:stocks).macro).to eq(:has_many)
  end

  it 'has many product_mappings' do
    expect(described_class.reflect_on_association(:product_mappings).macro).to eq(:has_many)
  end
end
