# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Order, type: :model do
  subject(:order) do
    described_class.new(company: company, customer_name: 'Cliente ACME')
  end

  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:other_company) { Company.create!(name: 'Other Corp', tax_id: '30-99999999-9') }
  let(:service) do
    Service.create!(service_name: 'Mercado Libre', type: 'ecommerce',
                    uri: 'https://api.mercadolibre.com', http_method: 'GET')
  end

  it 'is valid with required attributes' do
    expect(order).to be_valid
  end

  it 'defaults status to pending' do
    order.save!
    expect(order.status).to eq('pending')
  end

  it 'is invalid without a company' do
    order.company = nil
    expect(order).not_to be_valid
  end

  it 'is invalid without a customer_name' do
    order.customer_name = nil
    expect(order).not_to be_valid
  end

  it 'accepts only valid statuses' do
    Order::STATUSES.each do |status|
      order.status = status
      expect(order).to be_valid
    end
  end

  it 'rejects an unknown status' do
    order.status = 'shipped'
    expect(order).not_to be_valid
  end

  it 'allows multiple manual orders without external_order_id', :aggregate_failures do
    order.save!
    another = described_class.new(company: company, customer_name: 'Otro Cliente')
    expect(another).to be_valid
  end

  it 'enforces external_order_id uniqueness scoped to company' do
    order.external_order_id = 'ML-123'
    order.save!
    duplicate = described_class.new(company: company, customer_name: 'Otro',
                                    external_order_id: 'ML-123')
    expect(duplicate).not_to be_valid
  end

  it 'allows the same external_order_id across different companies' do
    order.external_order_id = 'ML-123'
    order.save!
    other = described_class.new(company: other_company, customer_name: 'Otro',
                                external_order_id: 'ML-123')
    expect(other).to be_valid
  end

  it 'rejects a company_integration from another company', :aggregate_failures do
    order.company_integration = CompanyIntegration.create!(company: other_company, service: service)
    expect(order).not_to be_valid
    expect(order.errors[:company_integration]).to include('must belong to the same company')
  end

  it 'allows a company_integration from the same company' do
    order.company_integration = CompanyIntegration.create!(company: company, service: service)
    expect(order).to be_valid
  end

  it 'is queryable within a tenant context' do
    Current.company_id = company.id
    expect { described_class.count }.not_to raise_error
  ensure
    Current.reset
  end

  it 'belongs to a company' do
    expect(described_class.reflect_on_association(:company).macro).to eq(:belongs_to)
  end

  it 'belongs to a company_integration as optional', :aggregate_failures do
    expect(described_class.reflect_on_association(:company_integration).macro).to eq(:belongs_to)
    expect(order.company_integration).to be_nil
  end

  it 'has many order_items' do
    expect(described_class.reflect_on_association(:order_items).macro).to eq(:has_many)
  end

  # ------------------------------------------------------------------ TESIS-114
  describe 'total_amount' do
    let(:product) { Product.create!(company: company, sku: 'SKU-001', name: 'Widget Alpha') }

    def add_line(quantity:, unit_price:)
      OrderItem.create!(order: order, product: product, quantity: quantity,
                        unit_price: unit_price)
    end

    it 'is optional' do
      order.total_amount = nil
      expect(order).to be_valid
    end

    it 'rejects a negative amount' do
      order.total_amount = -1
      expect(order).not_to be_valid
    end

    it 'accepts zero' do
      order.total_amount = 0
      expect(order).to be_valid
    end

    describe '#items_total' do
      it 'is zero for an order without lines' do
        order.save!
        expect(order.items_total).to eq(0)
      end

      it 'multiplies quantity by unit price' do
        order.save!
        add_line(quantity: 3, unit_price: 150.50)

        expect(order.items_total).to eq(451.50)
      end

      it 'adds up every line' do
        order.save!
        add_line(quantity: 2, unit_price: 100)
        add_line(quantity: 1, unit_price: 49.99)

        expect(order.items_total).to eq(249.99)
      end

      # Los centavos tienen que sobrevivir: con floats, 0.1 * 3 da
      # 0.30000000000000004 y el total de una venta larga se corre.
      it 'keeps the cents exact' do
        order.save!
        3.times { add_line(quantity: 1, unit_price: 0.1) }

        expect(order.items_total).to eq(BigDecimal('0.3'))
      end
    end

    # Segunda línea de defensa, mismo criterio que stocks_quantity_non_negative:
    # la validación del modelo no corre en update_all, upsert_all ni SQL crudo,
    # y un total negativo en la tabla que barren los KPIs (TESIS-64) es plata
    # inventada.
    describe 'the CHECK constraint at the database level' do
      it 'rejects a negative total written via update_all, which skips model validations' do
        order.save!

        expect do
          described_class.where(id: order.id).update_all(total_amount: -1) # rubocop:disable Rails/SkipsModelValidations
        end.to raise_error(ActiveRecord::CheckViolation)
      end
    end
  end
end
