# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Reports::DelayedShipments do
  let(:company) { Company.create!(name: 'Norte', tax_id: '30-11111111-1') }
  # 12 h de Argentina del 2 de octubre.
  let(:now) { Time.zone.parse('2026-10-02 15:00:00 UTC') }
  let(:window) { Reports::Window.new(period: '7d', now: now) }
  let(:warehouse) { Warehouse.create!(company: company, name: 'Central', zip_code: '1900', address: 'Calle 1') }

  around { |example| Current.set(company_id: company.id) { example.run } }

  def today = now.to_date

  def shipment(status:, promised:, units: 1, customer: 'Cliente')
    order = Order.create!(company: company, customer_name: customer)
    product = Product.create!(company: company, sku: "SKU-#{order.id}", name: 'Producto')
    OrderItem.create!(order: order, product: product, quantity: units, unit_price: 10)
    Shipment.create!(company: company, order: order, status: status, promised_delivery_on: promised,
                     origin_warehouse: warehouse)
  end

  def delivered(promised:, on:)
    shipment(status: 'delivered', promised: promised).tap do |delivered_one|
      ShipmentEvent.create!(shipment: delivered_one, internal_status: 'delivered',
                            external_status: 'Entregado', occurred_at: on)
    end
  end

  def rows = described_class.new(window: window).call

  def summary = described_class.new(window: window).summary

  describe 'the open delays' do
    before do
      shipment(status: 'in_transit', promised: today - 1, customer: 'Un día')
      shipment(status: 'ready_to_ship', promised: today - 4, customer: 'Cuatro días', units: 6)
      shipment(status: 'in_transit', promised: today, customer: 'En plazo')
    end

    it 'counts the shipments on their way past their promise, and says one is critical' do
      expect(summary).to eq(count: 2, critical: true)
    end

    # Las de más días de demora primero: son las críticas.
    it 'lists the most delayed first, with how late and how critical', :aggregate_failures do
      expect(rows.pluck(:days_late, :status)).to eq([[4, 'critical'], [1, 'investigating']])
      expect(rows.first).to include(units: 6, origin_warehouse: { id: warehouse.id, name: 'Central' },
                                    promised_delivery_on: today - 4)
    end
  end

  it 'is not critical while every delay is shorter than the critical days' do
    shipment(status: 'in_transit', promised: today - 2)

    expect(summary).to eq(count: 1, critical: false)
  end

  describe 'the resolved delays' do
    before do
      delivered(promised: today - 3, on: now - 1.day)
      delivered(promised: today - 1, on: now - 1.day)
      # Entregada tarde, pero antes de la ventana.
      delivered(promised: today - 12, on: now - 10.days)
    end

    it 'lists the deliveries of the window that arrived after the promise' do
      expect(rows.pluck(:days_late, :status)).to eq([[2, 'resolved']])
    end

    it 'does not count them as active' do
      expect(summary).to eq(count: 0, critical: false)
    end
  end

  # 23 h de Argentina del día prometido: en UTC ya es el día siguiente, y la
  # entrega igual llegó a tiempo.
  it 'cuts the delivery day in Argentina' do
    delivered(promised: today - 1, on: Time.zone.parse('2026-10-02 02:00:00 UTC'))

    expect(rows).to eq([])
  end

  it 'shows at most the limit, the open ones first' do
    stub_const("#{described_class}::LIMIT", 2)
    delivered(promised: today - 3, on: now - 1.day)
    2.times { |index| shipment(status: 'in_transit', promised: today - 1, customer: "Abierta #{index}") }

    expect(rows.pluck(:status)).to eq(%w[investigating investigating])
  end

  it 'fills the rest of the limit with the resolved ones' do
    stub_const("#{described_class}::LIMIT", 2)
    delivered(promised: today - 3, on: now - 1.day)
    shipment(status: 'in_transit', promised: today - 1)

    expect(rows.pluck(:status)).to eq(%w[investigating resolved])
  end
end
