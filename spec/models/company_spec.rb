require 'rails_helper'

RSpec.describe Company, type: :model do
  subject(:company) { described_class.new(name: 'Acme', tax_id: '20-12345678-9') }

  it 'is valid with name and tax_id' do
    expect(company).to be_valid
  end

  it 'is invalid without a name' do
    company.name = nil
    expect(company).not_to be_valid
  end

  it 'is invalid without a tax_id' do
    company.tax_id = nil
    expect(company).not_to be_valid
  end

  it 'enforces tax_id uniqueness' do
    company.save!
    duplicate = described_class.new(name: 'Other', tax_id: company.tax_id)
    expect(duplicate).not_to be_valid
  end

  it 'defaults is_active to true' do
    company.save!
    expect(company.is_active).to be(true)
  end

  describe 'associations' do
    it 'has many users' do
      expect(described_class.reflect_on_association(:users).macro).to eq(:has_many)
    end

    it 'has many warehouses' do
      expect(described_class.reflect_on_association(:warehouses).macro).to eq(:has_many)
    end

    it 'destroys dependent users and warehouses' do
      company.save!
      company.users.create!(email: 'a@a.com', password: '123456')
      company.warehouses.create!(name: 'Central', zip_code: '1900', address: 'Calle 1')

      expect { company.destroy }.to change(User, :count).by(-1).and change(Warehouse, :count).by(-1)
    end
  end
end
