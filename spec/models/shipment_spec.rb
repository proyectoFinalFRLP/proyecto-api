# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Shipment, type: :model do
  subject(:shipment) do
    described_class.new(company: company, order: order)
  end

  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:other_company) { Company.create!(name: 'Other Corp', tax_id: '30-99999999-9') }
  let(:order) { Order.create!(company: company, customer_name: 'Cliente ACME') }
  let(:service) do
    Service.create!(service_name: 'Andreani', type: 'courier',
                    uri: 'https://apis.andreani.com', http_method: 'POST')
  end

  it 'is valid with required attributes' do
    expect(shipment).to be_valid
  end

  it 'defaults status to pending' do
    shipment.save!
    expect(shipment.status).to eq('pending')
  end

  it 'accepts a non-negative shipping_cost' do
    shipment.shipping_cost = 1500.50
    expect(shipment).to be_valid
  end

  it 'accepts nil shipping_cost' do
    shipment.shipping_cost = nil
    expect(shipment).to be_valid
  end

  it 'rejects a negative shipping_cost', :aggregate_failures do
    shipment.shipping_cost = -100
    expect(shipment).not_to be_valid
    expect(shipment.errors[:shipping_cost]).to include('must be greater than or equal to 0')
  end

  # decimal(10,2): lo que no entra en la columna es un error de validación, no
  # un RangeError de la base (TESIS-131).
  it 'accepts the largest shipping_cost the column holds' do
    shipment.shipping_cost = BigDecimal('99999999.99')
    expect(shipment).to be_valid
  end

  it 'rejects a shipping_cost that does not fit the column', :aggregate_failures do
    shipment.shipping_cost = Shipment::MAX_SHIPPING_COST
    expect(shipment).not_to be_valid
    expect(shipment.errors[:shipping_cost]).to include('must be less than 100000000')
  end

  it 'is invalid without a company' do
    shipment.company = nil
    expect(shipment).not_to be_valid
  end

  it 'is invalid without an order' do
    shipment.order = nil
    expect(shipment).not_to be_valid
  end

  it 'accepts only valid statuses' do
    described_class::STATUSES.each do |status|
      shipment.status = status
      expect(shipment).to be_valid
    end
  end

  it 'rejects an unknown status' do
    shipment.status = 'lost'
    expect(shipment).not_to be_valid
  end

  it 'enforces one shipment per order (model validation)', :aggregate_failures do
    shipment.save!
    duplicate = described_class.new(company: company, order: order)
    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:order_id]).to include('has already been taken')
  end

  it 'enforces one shipment per order at the database level' do
    shipment.save!
    duplicate = described_class.new(company: company, order: order)
    expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it 'allows shipments for different orders' do
    other_order = Order.create!(company: company, customer_name: 'Otro Cliente')
    described_class.create!(company: company, order: order)
    second = described_class.new(company: company, order: other_order)
    expect(second).to be_valid
  end

  it 'rejects an order from another company', :aggregate_failures do
    shipment.order = Order.create!(company: other_company, customer_name: 'Orden Ajena')
    expect(shipment).not_to be_valid
    expect(shipment.errors[:base]).to include('order must belong to the same company as the shipment')
  end

  it 'rejects a company_integration from another company', :aggregate_failures do
    shipment.company_integration = CompanyIntegration.create!(company: other_company, service: service)
    expect(shipment).not_to be_valid
    expect(shipment.errors[:company_integration]).to include('must belong to the same company')
  end

  it 'allows a company_integration from the same company' do
    shipment.company_integration = CompanyIntegration.create!(company: company, service: service)
    expect(shipment).to be_valid
  end

  # Un envío lo lleva un operador logístico y nada más. El camino de producción
  # ya elegía entre integraciones de tipo courier, pero una asignación directa
  # —el panel, un seed, un job nuevo— podía colgarle un canal de ecommerce, y la
  # columna «Operador logístico» del listado de órdenes mostraría «Tiendanube»
  # como si fuera cierto.
  it 'rejects a company_integration that is not a courier', :aggregate_failures do
    channel = Service.create!(service_name: 'Tiendanube', type: 'ecommerce',
                              http_method: 'POST', uri: 'https://api.tiendanube.test/orders')
    shipment.company_integration = CompanyIntegration.create!(company: company, service: channel)

    expect(shipment).not_to be_valid
    expect(shipment.errors[:company_integration]).to include('must be a courier integration')
  end

  describe '.in_flight' do
    let(:other_order) { Order.create!(company: company, customer_name: 'Ana') }

    def shipment_with(status:, tracking: 'TRK-1', on: order)
      described_class.create!(company: company, order: on, status: status,
                              tracking_number: tracking)
    end

    it 'includes the shipments the courier still has to deliver' do
      ready = shipment_with(status: 'ready_to_ship')
      moving = shipment_with(status: 'in_transit', tracking: 'TRK-2', on: other_order)
      expect(described_class.in_flight).to contain_exactly(ready, moving)
    end

    it 'excludes delivered shipments' do
      shipment_with(status: 'delivered')
      expect(described_class.in_flight).to be_empty
    end

    it 'excludes shipments without a tracking number to ask for' do
      shipment_with(status: 'pending', tracking: nil)
      shipment_with(status: 'ready_to_ship', tracking: nil, on: other_order)
      expect(described_class.in_flight).to be_empty
    end
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

  it 'belongs to an order' do
    expect(described_class.reflect_on_association(:order).macro).to eq(:belongs_to)
  end

  it 'belongs to a company_integration as optional', :aggregate_failures do
    expect(described_class.reflect_on_association(:company_integration).macro).to eq(:belongs_to)
    expect(shipment.company_integration).to be_nil
  end

  it 'has many shipment_events' do
    expect(described_class.reflect_on_association(:shipment_events).macro).to eq(:has_many)
  end
end
