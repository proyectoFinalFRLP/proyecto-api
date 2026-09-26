# frozen_string_literal: true

require 'rails_helper'

# El catálogo es la tabla que más endpoints toca, y hasta TESIS-93 su policy no
# tenía spec propio: el aislamiento se verificaba sólo de punta a punta, por
# HTTP. Esto fija la regla en el lugar donde vive.
RSpec.describe ProductPolicy do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:other_company) { Company.create!(name: 'Rival', tax_id: '30-88888888-1') }
  let(:user) { User.create!(email: 'a@acme.com', password: 'pass123', company: company) }

  def product_for(a_company, sku: 'SKU-1')
    Current.set(company_id: a_company.id) do
      Product.create!(company: a_company, sku: sku, name: 'Widget')
    end
  end

  describe '#index?' do
    it 'allows an authenticated user' do
      expect(described_class.new(user, Product).index?).to be(true)
    end

    it 'refuses without a user' do
      expect(described_class.new(nil, Product).index?).to be(false)
    end
  end

  describe '#create?' do
    it 'allows an authenticated user' do
      expect(described_class.new(user, Product).create?).to be(true)
    end

    it 'refuses without a user' do
      expect(described_class.new(nil, Product).create?).to be(false)
    end
  end

  describe '#show?' do
    it 'allows a product of the same company' do
      expect(described_class.new(user, product_for(company)).show?).to be(true)
    end

    it 'refuses a product of another company' do
      expect(described_class.new(user, product_for(other_company)).show?).to be(false)
    end
  end

  describe '#update?' do
    it 'allows a product of the same company' do
      expect(described_class.new(user, product_for(company)).update?).to be(true)
    end

    it 'refuses a product of another company' do
      expect(described_class.new(user, product_for(other_company)).update?).to be(false)
    end
  end

  describe '#destroy?' do
    it 'allows a product of the same company' do
      expect(described_class.new(user, product_for(company)).destroy?).to be(true)
    end

    it 'refuses a product of another company' do
      expect(described_class.new(user, product_for(other_company)).destroy?).to be(false)
    end
  end

  # Igual que en OrderPolicy: los ejemplos corren con `unscoped` porque si no el
  # default_scope de CompanyScoped filtraría antes y el Scope pasaría sin hacer
  # nada.
  describe 'Scope#resolve' do
    it 'returns the products of the company of the user' do
      mine = product_for(company)
      product_for(other_company, sku: 'SKU-2')

      resolved = described_class::Scope.new(user, Product.unscoped).resolve

      expect(resolved.pluck(:id)).to eq([mine.id])
    end

    it 'returns nothing when the company has no products' do
      product_for(other_company, sku: 'SKU-2')

      resolved = described_class::Scope.new(user, Product.unscoped).resolve

      expect(resolved).to be_empty
    end
  end
end
