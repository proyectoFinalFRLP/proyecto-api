# frozen_string_literal: true

require 'rails_helper'

# Los depósitos son el recurso que TESIS-108 pasó a devolver entero (hasta el
# techo) para llenar los selects del frontend, así que su Scope es lo único que
# separa los nodos de una empresa de los de otra en esa respuesta.
RSpec.describe WarehousePolicy do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:other_company) { Company.create!(name: 'Rival', tax_id: '30-88888888-1') }
  let(:user) { User.create!(email: 'a@acme.com', password: 'pass123', company: company) }

  def warehouse_for(a_company, name: 'Central')
    Current.set(company_id: a_company.id) do
      Warehouse.create!(company: a_company, name: name, zip_code: '1900', address: 'Calle 1')
    end
  end

  describe '#index?' do
    it 'allows an authenticated user' do
      expect(described_class.new(user, Warehouse).index?).to be(true)
    end

    it 'refuses without a user' do
      expect(described_class.new(nil, Warehouse).index?).to be(false)
    end
  end

  describe '#create?' do
    it 'allows an authenticated user' do
      expect(described_class.new(user, Warehouse).create?).to be(true)
    end

    it 'refuses without a user' do
      expect(described_class.new(nil, Warehouse).create?).to be(false)
    end
  end

  describe '#show?' do
    it 'allows a warehouse of the same company' do
      expect(described_class.new(user, warehouse_for(company)).show?).to be(true)
    end

    it 'refuses a warehouse of another company' do
      expect(described_class.new(user, warehouse_for(other_company)).show?).to be(false)
    end
  end

  describe '#update?' do
    it 'allows a warehouse of the same company' do
      expect(described_class.new(user, warehouse_for(company)).update?).to be(true)
    end

    it 'refuses a warehouse of another company' do
      expect(described_class.new(user, warehouse_for(other_company)).update?).to be(false)
    end
  end

  describe '#destroy?' do
    it 'allows a warehouse of the same company' do
      expect(described_class.new(user, warehouse_for(company)).destroy?).to be(true)
    end

    it 'refuses a warehouse of another company' do
      expect(described_class.new(user, warehouse_for(other_company)).destroy?).to be(false)
    end
  end

  describe 'Scope#resolve' do
    it 'returns the warehouses of the company of the user' do
      mine = warehouse_for(company)
      warehouse_for(other_company, name: 'Ajeno')

      resolved = described_class::Scope.new(user, Warehouse.unscoped).resolve

      expect(resolved.pluck(:id)).to eq([mine.id])
    end
  end
end
