# frozen_string_literal: true

require 'rails_helper'

# Los seeds completos, como los corre `bin/rails db:seed` en desarrollo: los
# couriers de ejemplo (Andreani, Correo Argentino) quedan inactivos y los envíos
# de Norte pasan a OCA (db/seeds/demo_couriers.rb), también en una base que se
# sembró antes de este cambio.
RSpec.describe 'Demo couriers seeds' do # rubocop:disable RSpec/DescribeClass
  def seed!
    load Rails.root.join('db/seeds.rb')
  ensure
    Current.reset
  end

  def norte = Company.find_by!(slug: 'norte')

  def in_norte(&) = Current.set(company_id: norte.id, &)

  def integrations_of(*service_names)
    CompanyIntegration.unscoped.joins(:service)
                      .where(company_id: norte.id, services: { service_name: service_names })
  end

  def fake_couriers = integrations_of('Andreani', 'Andreani - Cotización', 'Correo Argentino')

  def oca = integrations_of('OCA').first!

  def shipped = in_norte { Shipment.where.not(company_integration_id: nil).to_a }

  # `seeds.rb` imprime un resumen (se silencia) y deja el adaptador de jobs en
  # `:test` (se restaura). La conexión de demo con OCA sólo se siembra en
  # desarrollo.
  around do |example|
    adapter = ActiveJob::Base.queue_adapter
    example.run
  ensure
    ActiveJob::Base.queue_adapter = adapter
  end

  before { allow($stdout).to receive(:puts) }

  context 'when in development' do
    before do
      allow(Rails.env).to receive(:development?).and_return(true)
      seed!
    end

    it 'keeps the example couriers, but inactive', :aggregate_failures do
      expect(fake_couriers.count).to eq(3)
      expect(fake_couriers.pluck(:is_active)).to all(be(false))
      expect(Service.where(service_name: ['Andreani', 'Correo Argentino']).count).to eq(2)
    end

    it 'dispatches every seeded shipment with OCA', :aggregate_failures do
      expect(shipped).not_to be_empty
      expect(shipped.map(&:company_integration_id).uniq).to eq([oca.id])
    end

    it 'leaves no Andreani tracking number or label', :aggregate_failures do
      expect(shipped.map(&:tracking_number)).to all(start_with('DEMO-OCA-'))
      expect(shipped.map(&:shipping_label_url)).to all(be_nil)
    end

    it 'seeds no invented history' do
      expect(in_norte { Shipment.where('tracking_number ~ ?', '^DEMO-[0-9]{6}$').count }).to eq(0)
    end

    it 'leaves nothing to add or reactivate when the seeds run again', :aggregate_failures do
      expect { seed! }.not_to(change do
        [Order.unscoped.count, Shipment.unscoped.count, ShipmentEvent.unscoped.count,
         CompanyIntegration.unscoped.count, CompanyIntegration.unscoped.where(is_active: true).count]
      end)
      expect(shipped.map(&:company_integration_id).uniq).to eq([oca.id])
    end

    # Lo que tiene una base sembrada antes: los envíos con Andreani, su número
    # `AND-` y la etiqueta de apis.andreani.com, y los couriers activos.
    context 'when the database was seeded before' do
      let(:shipment) { shipped.first }

      before do
        fake_couriers.update_all(is_active: true) # rubocop:disable Rails/SkipsModelValidations
        shipment.update_columns( # rubocop:disable Rails/SkipsModelValidations
          company_integration_id: integrations_of('Andreani').first!.id,
          tracking_number: 'AND-100000001',
          shipping_label_url: 'https://apis.andreani.com/labels/AND-100000001.pdf'
        )
        seed!
      end

      it 'repoints its shipments to OCA' do
        expect(shipment.reload).to have_attributes(company_integration_id: oca.id,
                                                   tracking_number: 'DEMO-OCA-100000001',
                                                   shipping_label_url: nil)
      end

      it 'deactivates its example couriers' do
        expect(fake_couriers.pluck(:is_active)).to all(be(false))
      end
    end
  end

  # Fuera de desarrollo no se conecta OCA: las de ejemplo se apagan igual, y
  # los envíos esperan a que alguien conecte OCA (`demo:connect_oca`).
  context 'without an OCA integration' do
    before { seed! }

    it 'still deactivates the example couriers and keeps their shipments', :aggregate_failures do
      expect(fake_couriers.pluck(:is_active)).to all(be(false))
      expect(integrations_of('OCA')).to be_empty
      expect(shipped.map(&:company_integration_id).uniq)
        .to eq([integrations_of('Andreani').first!.id])
    end
  end
end
