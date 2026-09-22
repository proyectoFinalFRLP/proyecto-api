# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Shipments::RegisterTrackingEvent, type: :poro do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:shipment) do
    order = Order.create!(company: company, customer_name: 'Juan Perez', status: 'paid')
    Shipment.create!(company: company, company_integration: courier_integration(company: company),
                     order: order, tracking_number: 'AND-001', status: 'ready_to_ship')
  end

  before { Current.company_id = company.id }

  # Lo que devuelve TranslateTrackingPayload: el estado crudo y su traducción.
  def translated(external_status: 'En camino', internal_status: 'in_transit',
                 occurred_at: Time.zone.parse('2026-09-20T10:00:00Z'), description: 'CABA')
    { tracking_number: 'AND-001', external_status: external_status,
      internal_status: internal_status, occurred_at: occurred_at, description: description }
  end

  def register(**attrs)
    described_class.new(shipment: shipment, translated: translated(**attrs)).call
  end

  it 'creates the event with the raw and the translated status' do
    expect(register).to have_attributes(shipment: shipment, external_status: 'En camino',
                                        internal_status: 'in_transit', description: 'CABA')
  end

  it 'advances the shipment to the translated status' do
    expect { register }.to change { shipment.reload.status }.from('ready_to_ship').to('in_transit')
  end

  context 'when the template could not translate the status' do
    it 'registers the event as informative without moving the shipment', :aggregate_failures do
      event = register(external_status: 'Retenido en aduana', internal_status: nil)

      expect(event.internal_status).to eq('ready_to_ship')
      expect(shipment.reload.status).to eq('ready_to_ship')
    end
  end

  context 'when the exact same movement was already registered' do
    before { register }

    it 'does not create a second event and returns nil', :aggregate_failures do
      result = :not_nil
      expect { result = register }.not_to change(ShipmentEvent, :count)
      expect(result).to be_nil
    end
  end

  # La card pide registrar "un nuevo movimiento dentro del mismo estado": el
  # paquete sigue en camino pero pasó por otra sucursal.
  context 'when the same status is reported with a newer timestamp' do
    before { register }

    it 'registers the new movement' do
      expect { register(occurred_at: Time.zone.parse('2026-09-20T15:00:00Z'), description: 'Rosario') }
        .to change(ShipmentEvent, :count).by(1)
    end
  end

  context 'when an older movement arrives after a newer one' do
    before { register(external_status: 'Entregado', internal_status: 'delivered') }

    it 'discards it without moving the status backwards', :aggregate_failures do
      expect { register(occurred_at: Time.zone.parse('2026-09-19T10:00:00Z')) }
        .not_to change(ShipmentEvent, :count)
      expect(shipment.reload.status).to eq('delivered')
    end
  end

  context 'when the courier does not date its movements' do
    before { register(occurred_at: nil) }

    it 'falls back to the processing time' do
      expect(shipment.shipment_events.last.occurred_at).to be_within(5.seconds).of(Time.current)
    end

    it 'does not duplicate the last status on a second report' do
      expect { register(occurred_at: nil) }.not_to change(ShipmentEvent, :count)
    end

    it 'still registers a different status' do
      expect { register(external_status: 'Entregado', internal_status: 'delivered', occurred_at: nil) }
        .to change(ShipmentEvent, :count).by(1)
    end
  end

  context 'when another worker writes the same event between the check and the insert' do
    before do
      allow(ShipmentEvent).to receive(:create!).and_raise(ActiveRecord::RecordNotUnique)
    end

    it 'treats it as already registered instead of failing' do
      expect(register).to be_nil
    end
  end
end
