# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Stock, type: :model do
  subject(:stock) do
    described_class.new(product: product, warehouse: warehouse, quantity: 10)
  end

  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:other_company) { Company.create!(name: 'Other Corp', tax_id: '30-99999999-9') }
  let(:product) { Product.create!(company: company, sku: 'SKU-001', name: 'Widget Alpha') }
  let(:warehouse) { Warehouse.create!(company: company, name: 'Central', zip_code: '1900', address: 'Calle 1') }

  it 'is valid with required attributes' do
    expect(stock).to be_valid
  end

  it 'defaults quantity to 0' do
    expect(described_class.new.quantity).to eq(0)
  end

  it 'is invalid without a product' do
    stock.product = nil
    expect(stock).not_to be_valid
  end

  it 'is invalid without a warehouse' do
    stock.warehouse = nil
    expect(stock).not_to be_valid
  end

  it 'validates quantity is not negative' do
    stock.quantity = -1
    expect(stock).not_to be_valid
  end

  it 'enforces uniqueness of product scoped to warehouse' do
    stock.save!
    duplicate = described_class.new(product: product, warehouse: warehouse, quantity: 5)
    expect(duplicate).not_to be_valid
  end

  it 'allows same product in different warehouses' do
    stock.save!
    other_warehouse = Warehouse.create!(company: company, name: 'North', zip_code: '1901', address: 'Calle 2')
    other_stock = described_class.new(product: product, warehouse: other_warehouse, quantity: 5)
    expect(other_stock).to be_valid
  end

  it 'rejects a product and warehouse from different companies', :aggregate_failures do
    stock.warehouse = Warehouse.create!(company: other_company, name: 'Other WH',
                                        zip_code: '2000', address: 'Calle Otra')
    expect(stock).not_to be_valid
    expect(stock.errors[:base]).to include('product and warehouse must belong to the same company')
  end

  it 'is queryable within a tenant context' do
    Current.company_id = company.id
    expect { described_class.count }.not_to raise_error
  ensure
    Current.reset
  end

  it 'belongs to a product' do
    expect(described_class.reflect_on_association(:product).macro).to eq(:belongs_to)
  end

  it 'belongs to a warehouse' do
    expect(described_class.reflect_on_association(:warehouse).macro).to eq(:belongs_to)
  end

  # La validación de ActiveRecord (numericality >= 0) es la primera línea de
  # defensa, pero sólo corre en el ciclo de vida normal del modelo:
  # operaciones que lo saltean (update_all, upsert_all, SQL crudo) nunca
  # ejecutan validaciones. El CHECK constraint `stocks_quantity_non_negative`
  # (ver db/migrate/20260810120000_add_quantity_check_constraint_to_stocks.rb)
  # es la segunda línea de defensa, a nivel base de datos, para esos casos.
  # El primer ejemplo no hace nada después del expect: el UPDATE que viola el
  # CHECK deja abortada la transacción del ejemplo, así que no se puede
  # seguir usando la conexión.
  describe 'the quantity CHECK constraint at the database level' do
    it 'rejects a negative quantity written via update_all, which skips model validations' do
      stock.save!

      # Saltear las validaciones es exactamente lo que este ejemplo necesita
      # provocar: es el escenario contra el que existe el CHECK.
      expect do
        described_class.where(id: stock.id).update_all(quantity: -1) # rubocop:disable Rails/SkipsModelValidations
      end.to raise_error(ActiveRecord::CheckViolation)
    end

    it 'still fails the model validation first, with the error on :quantity', :aggregate_failures do
      invalid_stock = described_class.new(product: product, warehouse: warehouse, quantity: -1)

      expect(invalid_stock).not_to be_valid
      expect(invalid_stock.errors[:quantity]).to be_present
    end
  end
end
