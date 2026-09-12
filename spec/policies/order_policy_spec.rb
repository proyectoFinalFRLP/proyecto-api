# frozen_string_literal: true

require 'rails_helper'

RSpec.describe OrderPolicy do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:other_company) { Company.create!(name: 'Rival', tax_id: '30-88888888-1') }
  let(:user) { User.create!(email: 'a@acme.com', password: 'pass123', company: company) }

  def order_for(a_company)
    Current.set(company_id: a_company.id) do
      Order.create!(company: a_company, customer_name: 'Cliente', status: 'pending')
    end
  end

  describe '#index?' do
    it 'allows an authenticated user' do
      expect(described_class.new(user, Order).index?).to be(true)
    end

    it 'refuses without a user' do
      expect(described_class.new(nil, Order).index?).to be(false)
    end
  end

  describe '#show?' do
    it 'allows an order of the same company' do
      expect(described_class.new(user, order_for(company)).show?).to be(true)
    end

    it 'refuses an order of another company' do
      expect(described_class.new(user, order_for(other_company)).show?).to be(false)
    end
  end

  # El Scope es la segunda barrera: el aislamiento real lo da el default_scope
  # de CompanyScoped. Por eso los ejemplos corren con `unscoped`, que es la
  # única forma de comprobar que el Scope filtra por sí mismo y no porque el
  # default_scope ya lo hizo.
  describe 'Scope#resolve' do
    it 'returns the orders of the company of the user' do
      mine = order_for(company)
      order_for(other_company)

      resolved = described_class::Scope.new(user, Order.unscoped).resolve

      expect(resolved.pluck(:id)).to eq([mine.id])
    end

    it 'excludes the orders of another company' do
      order_for(company)
      theirs = order_for(other_company)

      resolved = described_class::Scope.new(user, Order.unscoped).resolve

      expect(resolved.pluck(:id)).not_to include(theirs.id)
    end
  end
end
