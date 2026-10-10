require 'rails_helper'

RSpec.describe Warehouse, type: :model do
  subject(:warehouse) do
    described_class.new(name: 'Central', zip_code: '1900', address: 'Calle 1', company: company)
  end

  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }

  it 'is valid with all required attributes' do
    expect(warehouse).to be_valid
  end

  it 'is invalid without a company' do
    warehouse.company = nil
    expect(warehouse).not_to be_valid
  end

  %i[name zip_code address].each do |attribute|
    it "is invalid without #{attribute}" do
      warehouse.public_send("#{attribute}=", nil)
      expect(warehouse).not_to be_valid
    end
  end

  it 'belongs to a company' do
    expect(described_class.reflect_on_association(:company).macro).to eq(:belongs_to)
  end

  describe 'destroying it' do
    let(:product) { Product.create!(company: company, sku: 'SKU-1', name: 'Producto') }

    before { warehouse.save! }

    # El `restrict_with_error` de `stocks` corre después y miraría la lista
    # cargada si no se reseteara.
    it 'goes through even when its empty stock rows were already loaded', :aggregate_failures do
      Stock.create!(product: product, warehouse: warehouse, quantity: 0)
      warehouse.stocks.load

      expect(warehouse.destroy).to be_truthy
      expect(Stock.count).to eq(0)
    end

    it 'is refused while a row holds units', :aggregate_failures do
      Stock.create!(product: product, warehouse: warehouse, quantity: 3)

      expect(warehouse.destroy).to be(false)
      expect(warehouse.errors.full_messages).to include(a_string_matching(/stocks/i))
    end
  end

  # Lo comprometido es lo vendido y todavía sin despachar: `DeductStock` ya lo
  # sacó de `stocks` al crear la orden, pero sigue ocupando lugar en el estante
  # hasta que el courier se lo lleva. Contar sólo las libres hacía que la barra
  # de capacidad del panel midiera menos ocupación de la real (TESIS-170).
  describe 'its stored units' do
    let(:product) { Product.create!(company: company, sku: 'SKU-1', name: 'Producto') }
    let(:otro) do
      described_class.create!(company: company, name: 'Satélite', zip_code: '1900',
                              address: 'Calle 2')
    end

    before do
      warehouse.save!
      Stock.create!(product: product, warehouse: warehouse, quantity: 10)
    end

    def sell(quantity, deposito: warehouse, status: 'paid', shipment_status: nil,
             ships: true)
      order = Order.create!(company: company, customer_name: 'Cliente', status: status,
                            requires_shipping: ships)
      OrderItem.create!(order: order, product: product, warehouse: deposito,
                        quantity: quantity, unit_price: 100)
      return order if shipment_status.nil?

      Shipment.create!(company: company, order: order, status: shipment_status,
                       tracking_number: shipment_status == 'pending' ? nil : 'AND-1')
      order
    end

    # El scope y el método tienen que contestar lo mismo: uno lo resuelve la
    # base en el SELECT del listado y el otro suma por asociación en el detalle.
    def del_scope = described_class.with_stored_units.find(warehouse.id).stored_units
    def del_metodo = described_class.find(warehouse.id).stored_units

    it 'counts the free units when nothing is sold', :aggregate_failures do
      expect(del_scope).to eq(10)
      expect(del_metodo).to eq(10)
    end

    it 'adds the units sold and not dispatched yet', :aggregate_failures do
      sell(3)

      expect(del_scope).to eq(13)
      expect(del_metodo).to eq(13)
    end

    it 'adds a sale whose shipment was opened but not dispatched' do
      sell(4, shipment_status: 'pending')

      expect(del_scope).to eq(14)
    end

    # Ya salió del depósito: deja de ocupar lugar porque deja de estar.
    it 'stops adding it once the shipment left' do
      sell(4, shipment_status: 'ready_to_ship')

      expect(del_scope).to eq(10)
    end

    it 'ignores a cancelled order' do
      sell(5, status: 'cancelled')

      expect(del_scope).to eq(10)
    end

    # En el mostrador registrar la venta y entregarla son el mismo momento
    # (TESIS-162): esas unidades ya salieron del estante.
    it 'does not add an order the customer picks up at the store' do
      sell(6, ships: false)

      expect(del_scope).to eq(10)
    end

    # La correlación de la subconsulta: si se perdiera, cada depósito sumaría
    # lo comprometido de todos.
    it 'only counts what was taken from this warehouse', :aggregate_failures do
      sell(3)
      sell(7, deposito: otro)

      expect(del_scope).to eq(13)
      expect(described_class.with_stored_units.find(otro.id).stored_units).to eq(7)
    end

    # Las líneas anteriores a TESIS-126 no dicen de qué depósito salieron.
    it 'leaves out a line that does not record its warehouse' do
      sell(3, deposito: nil)

      expect(del_scope).to eq(10)
    end
  end
end
