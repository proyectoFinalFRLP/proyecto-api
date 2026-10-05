# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Reports::BuildOverview do
  let(:company) { Company.create!(name: 'Norte', tax_id: '30-11111111-1') }
  let(:now) { Time.zone.parse('2026-10-02 15:00:00 UTC') }
  let(:window) { Reports::Window.new(period: '7d', now: now) }
  let(:product) { Product.create!(company: company, sku: 'R-1', name: 'Reportado') }

  around { |example| Current.set(company_id: company.id) { example.run } }

  def overview = described_class.new(window: window).call

  def order(at:, amount:, status: 'paid', units: 1)
    Order.create!(company: company, customer_name: 'Cliente', total_amount: amount,
                  status: status, created_at: at).tap do |created|
      OrderItem.create!(order: created, product: product, quantity: units, unit_price: amount)
    end
  end

  def dispatch(order, at:, with:, delivered: false)
    shipment = Shipment.create!(company: company, order: order, company_integration: with,
                                status: delivered ? 'delivered' : 'ready_to_ship')
    ShipmentEvent.create!(shipment: shipment, internal_status: 'ready_to_ship',
                          external_status: 'Etiqueta generada', occurred_at: at)
  end

  describe 'the sales of the window' do
    before do
      order(at: now - 1.day, amount: 1_000)
      order(at: now - 2.days, amount: 500)
      order(at: now - 1.day, amount: 9_999, status: 'cancelled')
      order(at: now - 10.days, amount: 750)
    end

    it 'adds up the revenue of the orders that were not cancelled' do
      expect(overview[:kpis][:revenue][:value]).to eq(1_500.0)
    end

    it 'counts those orders' do
      expect(overview[:kpis][:orders][:value]).to eq(2)
    end

    # 750 en la semana anterior contra 1.500 en esta.
    it 'compares them with the previous window of the same length' do
      expect(overview[:kpis][:revenue][:trend]).to eq(100.0)
    end
  end

  it 'answers no trend when the previous window had nothing' do
    order(at: now - 1.day, amount: 1_000)

    expect(overview[:kpis][:revenue]).to eq(value: 1_000.0, trend: nil)
  end

  it 'draws one point per day, the empty ones in zero', :aggregate_failures do
    order(at: now - 1.day, amount: 1_000)

    expect(overview[:curve].size).to eq(7)
    expect(overview[:curve].sum { |point| point[:orders] }).to eq(1)
    expect(overview[:curve].count { |point| point[:orders].zero? }).to eq(6)
  end

  describe 'the dispatched units and the carriers' do
    # Métodos y no `let`: el grupo ya hereda cuatro helpers y
    # RSpec/MultipleMemoizedHelpers corta en cinco.
    def andreani = CompanyIntegration.find_by(service: Service.find_by(service_name: 'Andreani'))
    def oca = CompanyIntegration.find_by(service: Service.find_by(service_name: 'OCA'))

    before do
      courier_integration(company: company, name: 'Andreani')
      courier_integration(company: company, name: 'OCA')
      dispatch(order(at: now - 3.days, amount: 10, units: 4), at: now - 1.day, with: andreani)
      dispatch(order(at: now - 3.days, amount: 10, units: 2), at: now - 2.days, with: andreani,
                                                              delivered: true)
      dispatch(order(at: now - 3.days, amount: 10, units: 7), at: now - 1.day, with: oca)
      # Despachada la semana anterior: no cuenta en esta ventana.
      dispatch(order(at: now - 9.days, amount: 10, units: 50), at: now - 8.days, with: oca)
    end

    # Por la fecha del despacho, no por la de la orden.
    it 'counts the units of the shipments dispatched in the window' do
      expect(overview[:kpis][:dispatched_units][:value]).to eq(13)
    end

    it 'counts the shipments of each carrier and how many were delivered' do
      expect(overview[:carriers]).to eq(
        [{ company_integration_id: andreani.id, name: 'Andreani', dispatched: 2, delivered: 1 },
         { company_integration_id: oca.id, name: 'OCA', dispatched: 1, delivered: 0 }]
      )
    end
  end

  # El modelo no tiene con qué calcularlos: `nil` y no un número inventado.
  it 'leaves out what the model cannot answer', :aggregate_failures do
    expect(overview[:kpis][:on_time_delivery_rate]).to be_nil
    expect(overview[:kpis][:active_anomalies]).to be_nil
  end

  it 'only sees the orders of the current tenant' do
    order_of_another_company

    expect(overview[:kpis][:revenue][:value]).to eq(0.0)
  end

  def order_of_another_company
    other = Company.create!(name: 'Sur', tax_id: '30-22222222-2')
    Current.set(company_id: other.id) do
      Order.create!(company: other, customer_name: 'Otro', total_amount: 5_000,
                    status: 'paid', created_at: now - 1.day)
    end
  end
end
