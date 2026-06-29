require 'rails_helper'

RSpec.describe Warehouse, type: :model do
  subject(:warehouse) do
    described_class.new(name: 'Central', zip_code: '1900', address: 'Calle 1', company: company)
  end

  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }

  it 'is valid with all required attributes' do
    expect(warehouse).to be_valid
  end

  it 'is invalid without a company' do
    warehouse.company = nil
    expect(warehouse).not_to be_valid
  end

  %i[name zip_code address].each do |attribute|
    it "is invalid without #{attribute}" do
      warehouse.public_send("#{attribute}=", nil)
      expect(warehouse).not_to be_valid
    end
  end

  it 'belongs to a company' do
    expect(described_class.reflect_on_association(:company).macro).to eq(:belongs_to)
  end
end
