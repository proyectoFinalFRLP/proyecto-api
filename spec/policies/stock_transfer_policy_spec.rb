# frozen_string_literal: true

require 'rails_helper'

# Una transferencia mueve unidades entre depósitos. `receive?` y `cancel?` son
# las dos acciones que cambian dónde están esas unidades, así que son las que
# tienen que mirar el tenant — `index?` y `create?` no reciben un registro y
# sólo pueden pedir un usuario.
RSpec.describe StockTransferPolicy do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:other_company) { Company.create!(name: 'Rival', tax_id: '30-88888888-1') }
  let(:user) { User.create!(email: 'a@acme.com', password: 'pass123', company: company) }

  def transfer_for(a_company)
    Current.set(company_id: a_company.id) do
      product = Product.create!(company: a_company, sku: "SKU-#{a_company.id}", name: 'Widget')
      origin = warehouse_for(a_company, 'Central', '1900')
      destination = warehouse_for(a_company, 'North', '1901')

      StockTransfer.create!(company: a_company, product: product, origin_warehouse: origin,
                            destination_warehouse: destination, quantity: 5,
                            dispatched_at: Time.current)
    end
  end

  def warehouse_for(a_company, name, zip)
    Warehouse.create!(company: a_company, name: name, zip_code: zip, address: "Calle #{zip}")
  end

  describe '#index?' do
    it 'allows an authenticated user' do
      expect(described_class.new(user, StockTransfer).index?).to be(true)
    end

    it 'refuses without a user' do
      expect(described_class.new(nil, StockTransfer).index?).to be(false)
    end
  end

  describe '#create?' do
    it 'allows an authenticated user' do
      expect(described_class.new(user, StockTransfer).create?).to be(true)
    end

    it 'refuses without a user' do
      expect(described_class.new(nil, StockTransfer).create?).to be(false)
    end
  end

  describe '#receive?' do
    it 'allows a transfer of the same company' do
      expect(described_class.new(user, transfer_for(company)).receive?).to be(true)
    end

    it 'refuses a transfer of another company' do
      expect(described_class.new(user, transfer_for(other_company)).receive?).to be(false)
    end
  end

  describe '#cancel?' do
    it 'allows a transfer of the same company' do
      expect(described_class.new(user, transfer_for(company)).cancel?).to be(true)
    end

    it 'refuses a transfer of another company' do
      expect(described_class.new(user, transfer_for(other_company)).cancel?).to be(false)
    end
  end

  describe 'Scope#resolve' do
    it 'returns the transfers of the company of the user' do
      mine = transfer_for(company)
      transfer_for(other_company)

      resolved = described_class::Scope.new(user, StockTransfer.unscoped).resolve

      expect(resolved.pluck(:id)).to eq([mine.id])
    end
  end
end
