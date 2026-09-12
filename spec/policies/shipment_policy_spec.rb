# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ShipmentPolicy, type: :policy do
  subject(:policy) { described_class.new(user, shipment) }

  let(:company) { Company.create!(name: 'Tenant A', tax_id: '30-11111111-1') }
  let(:user) { User.create!(email: 'a@example.com', password: 'password123', company: company) }
  let(:shipment) { shipment_for(company) }

  def shipment_for(owner)
    order = Order.create!(company: owner, customer_name: 'Ana', customer_zip_code: '5000',
                          customer_address: 'Av. Siempreviva 742')
    Shipment.create!(company: owner, order: order, status: 'pending')
  end

  def other_company
    @other_company ||= Company.create!(name: 'Tenant B', tax_id: '30-22222222-2')
  end

  it 'lets an authenticated user list the shipments' do
    expect(policy.index?).to be(true)
  end

  it 'lets a user read a shipment of their own company' do
    expect(policy.show?).to be(true)
  end

  # Los envíos son de sólo lectura por ahora: nacen al confirmar el despacho,
  # no por la API.
  it 'denies every write action', :aggregate_failures do
    expect(policy.create?).to be(false)
    expect(policy.update?).to be(false)
    expect(policy.destroy?).to be(false)
  end

  context 'when the shipment belongs to another company' do
    let(:shipment) { shipment_for(other_company) }

    it 'denies reading it' do
      expect(policy.show?).to be(false)
    end
  end

  describe 'Scope' do
    it 'resolves only the shipments of the company of the user' do
      own = shipment
      shipment_for(other_company)

      expect(described_class::Scope.new(user, Shipment).resolve).to contain_exactly(own)
    end
  end

  context 'without a user' do
    let(:user) { nil }

    it 'denies listing' do
      expect(policy.index?).to be(false)
    end

    it 'denies reading the record' do
      expect(policy.show?).to be(false)
    end
  end
end
