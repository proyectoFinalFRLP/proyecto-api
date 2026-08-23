# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ShipmentEvent, type: :model do
  subject(:shipment_event) do
    described_class.new(shipment: shipment, internal_status: 'in_transit',
                        external_status: 'En distribución',
                        occurred_at: Time.zone.parse('2026-08-11 08:30:00'))
  end

  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:order) { Order.create!(company: company, customer_name: 'Cliente ACME') }
  let(:shipment) { Shipment.create!(company: company, order: order) }

  it 'is valid with required attributes' do
    expect(shipment_event).to be_valid
  end

  it 'is invalid without a shipment' do
    shipment_event.shipment = nil
    expect(shipment_event).not_to be_valid
  end

  it 'is invalid without an internal_status' do
    shipment_event.internal_status = nil
    expect(shipment_event).not_to be_valid
  end

  it 'validates internal_status inclusion', :aggregate_failures do
    shipment_event.internal_status = 'invalid_status'
    expect(shipment_event).not_to be_valid
    expect(shipment_event.errors[:internal_status]).to include('is not included in the list')
  end

  it 'accepts valid internal_status values' do
    Shipment::STATUSES.each do |status|
      shipment_event.internal_status = status
      expect(shipment_event).to be_valid, "expected #{status} to be valid"
    end
  end

  it 'is invalid without an external_status' do
    shipment_event.external_status = nil
    expect(shipment_event).not_to be_valid
  end

  it 'is invalid without an occurred_at' do
    shipment_event.occurred_at = nil
    expect(shipment_event).not_to be_valid
  end

  it 'allows multiple events for the same shipment (bitácora)' do
    create_event('ready_to_ship')
    create_event('in_transit')
    expect(shipment.reload.shipment_events.count).to eq(2)
  end

  it 'belongs to a shipment' do
    expect(described_class.reflect_on_association(:shipment).macro).to eq(:belongs_to)
  end

  private

  def create_event(status)
    described_class.create!(shipment: shipment, internal_status: status,
                            external_status: 'En distribución',
                            occurred_at: Time.zone.parse('2026-08-11 08:30:00'))
  end
end
