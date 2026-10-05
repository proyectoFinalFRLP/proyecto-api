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

  def dispatch_days
    in_norte do
      ShipmentEvent.joins(:shipment).where(shipments: { order_id: demo_orders.map(&:id) },
                                           internal_status: 'ready_to_ship')
                   .pluck(:occurred_at).map(&:to_date).uniq
    end
  end

  it 'spreads four weeks of sales over many days' do
    days = demo_orders.map { |order| order.created_at.in_time_zone(DemoActivity::ZONE).to_date }

    expect(days.uniq.size).to be >= 15
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

  it 'keeps every demo sale inside the last thirty days' do
    oldest = demo_orders.map(&:created_at).min

    expect(oldest).to be > 30.days.ago
  end

  it 'leaves an exhausted and a pending event in the dead letter queue' do
    statuses = in_norte { FailedEvent.pluck(:status) }

    expect(statuses).to include('dead', 'pending')
  end
end
