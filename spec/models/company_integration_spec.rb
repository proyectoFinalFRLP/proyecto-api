require 'rails_helper'

RSpec.describe CompanyIntegration, type: :model do
  subject(:integration) { described_class.new(company: company, service: service) }

  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:service) do
    Service.create!(service_name: 'Andreani', type: 'courier',
                    uri: 'https://api.andreani.com', http_method: 'POST')
  end

  it 'is valid with company and service' do
    expect(integration).to be_valid
  end

  it 'defaults is_active to true and credentials to {}', :aggregate_failures do
    integration.save!
    expect(integration.is_active).to be(true)
    expect(integration.credentials).to eq({})
  end

  it 'belongs to company and service', :aggregate_failures do
    expect(described_class.reflect_on_association(:company).macro).to eq(:belongs_to)
    expect(described_class.reflect_on_association(:service).macro).to eq(:belongs_to)
  end

  it 'rejects a duplicate (company, service) pair via validation' do
    integration.save!
    expect(described_class.new(company: company, service: service)).not_to be_valid
  end

  it 'enforces the unique (company, service) index at the database level' do
    integration.save!
    duplicate = described_class.new(company: company, service: service)
    expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end
end
