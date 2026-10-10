# frozen_string_literal: true

require 'rails_helper'

# Los seeds completos, como los corre `bin/rails db:seed`, con la actividad
# histórica de la demo al final (db/seeds/demo_activity.rb).
RSpec.describe 'Demo activity seeds' do # rubocop:disable RSpec/DescribeClass
  def seed!
    load Rails.root.join('db/seeds.rb')
  ensure
    Current.reset
  end

  def norte = Company.find_by!(slug: 'norte')

  def in_norte(&) = Current.set(company_id: norte.id, &)

  def demo_orders
    in_norte { Order.where(customer_name: DemoActivity::SALES.map(&:second)).to_a }
  end

  # `seeds.rb` imprime un resumen (se silencia) y deja el adaptador de jobs en
  # `:test` (se restaura).
  around do |example|
    adapter = ActiveJob::Base.queue_adapter
    example.run
  ensure
    ActiveJob::Base.queue_adapter = adapter
  end

  before do
    allow($stdout).to receive(:puts)
    seed!
  end

  def demo_dispatches
    ShipmentEvent.joins(:shipment).where(shipments: { order_id: demo_orders.map(&:id) },
                                         internal_status: 'ready_to_ship')
  end

  def dispatch_days
    in_norte { demo_dispatches.pluck(:occurred_at).map(&:to_date).uniq }
  end

  # El mes contra el que Reportes compara «últimos 30 días».
  def previous_month = Reports::Window.new(period: '30d').previous_range

  def trends(period)
    in_norte do
      kpis = Reports::BuildOverview.new(window: Reports::Window.new(period:)).call[:kpis]
      kpis.slice(:orders, :revenue, :dispatched_units).transform_values { |kpi| kpi[:trend] }
    end
  end

  it 'spreads two months of sales over many days' do
    days = demo_orders.map { |order| order.created_at.in_time_zone(DemoActivity::ZONE).to_date }

    expect(days.uniq.size).to be >= 30
  end

  it 'leaves nothing to add when the seeds run again' do
    expect { seed! }.not_to(change { [Order.unscoped.count, FailedEvent.unscoped.count] })
  end

  # Reportes fecha el despacho por el evento `ready_to_ship` de la bitácora: sin
  # despachos repartidos en el tiempo, la curva y el volumen despachado no
  # tendrían qué mostrar.
  it 'dispatches part of the sales on different days' do
    expect(dispatch_days.size).to be > 5
  end

  # Más atrás no lo ve ninguna de las ventanas que comparan contra «últimos 30
  # días»: sería actividad que la demo carga y no muestra.
  it 'keeps every demo sale inside the last thirty days or the month before' do
    oldest = demo_orders.map(&:created_at).min

    expect(oldest).to be >= previous_month.begin
  end

  # Sin ventas en el mes anterior, Órdenes y Facturación salían sin tendencia, y
  # Volumen despachado comparaba contra las 4 unidades que los seeds de arriba
  # despachan en fechas fijas: +2.425 %. Las cuentas son sólo de la actividad,
  # para que esas 4 no alcancen a sostener el ejemplo cuando la fecha las tenga
  # adentro.
  it 'sells and dispatches in the month before the last thirty days', :aggregate_failures do
    in_norte do
      expect(Order.where(id: demo_orders.map(&:id), created_at: previous_month).count).to be >= 15
      expect(demo_dispatches.where(occurred_at: previous_month).count).to be >= 15
    end
  end

  # Una variación de cientos o de miles por ciento es lo primero que se ve en la
  # pantalla, y se lee como un error del reporte. «7d» es el período con el que
  # abre Reportes; «30d», el que se elige para ver el mes.
  #
  # ±30 y no ±50: con ±50 pasaba igual sin las ventas que completan el mes
  # anterior (+45 % de órdenes), que es justo la cifra que parece un error. Hoy
  # están entre −12 % y +20 %; las 4 unidades de fecha fija de los seeds de
  # arriba las mueven unos 2 puntos cuando salen de la ventana.
  %w[7d 30d].each do |period|
    it "shows believable #{period} trends in orders, revenue and dispatched units" do
      expect(trends(period).values).to all(be_within(30).of(0))
    end
  end

  # Son ventas pasadas, ya despachadas o canceladas: si descontaran stock, la
  # demo arrancaría con menos unidades que las que cargan los seeds de arriba.
  # Se borran y se vuelven a sembrar para medir sólo lo que hace la actividad.
  it 'does not move the stock', :aggregate_failures do
    in_norte { Order.where(id: demo_orders.map(&:id)).delete_all }
    stock = Stock.order(:id).pluck(:id, :quantity)

    DemoActivity.run

    expect(demo_orders.size).to eq(DemoActivity::SALES.size)
    expect(Stock.order(:id).pluck(:id, :quantity)).to eq(stock)
  end

  it 'leaves an exhausted and a pending event in the dead letter queue' do
    statuses = in_norte { FailedEvent.pluck(:status) }

    expect(statuses).to include('dead', 'pending')
  end
end
