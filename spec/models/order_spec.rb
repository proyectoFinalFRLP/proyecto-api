# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Order, type: :model do
  subject(:order) do
    described_class.new(company: company, customer_name: 'Cliente ACME')
  end

  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:other_company) { Company.create!(name: 'Other Corp', tax_id: '30-99999999-9') }
  let(:service) do
    Service.create!(service_name: 'Mercado Libre', type: 'ecommerce',
                    uri: 'https://api.mercadolibre.com', http_method: 'GET')
  end

  it 'is valid with required attributes' do
    expect(order).to be_valid
  end

  it 'defaults status to pending' do
    order.save!
    expect(order.status).to eq('pending')
  end

  it 'is invalid without a company' do
    order.company = nil
    expect(order).not_to be_valid
  end

  it 'is invalid without a customer_name' do
    order.customer_name = nil
    expect(order).not_to be_valid
  end

  it 'accepts only valid statuses' do
    Order::STATUSES.each do |status|
      order.status = status
      expect(order).to be_valid
    end
  end

  it 'rejects an unknown status' do
    order.status = 'shipped'
    expect(order).not_to be_valid
  end

  it 'allows multiple manual orders without external_order_id', :aggregate_failures do
    order.save!
    another = described_class.new(company: company, customer_name: 'Otro Cliente')
    expect(another).to be_valid
  end

  it 'enforces external_order_id uniqueness scoped to company' do
    order.external_order_id = 'ML-123'
    order.save!
    duplicate = described_class.new(company: company, customer_name: 'Otro',
                                    external_order_id: 'ML-123')
    expect(duplicate).not_to be_valid
  end

  it 'allows the same external_order_id across different companies' do
    order.external_order_id = 'ML-123'
    order.save!
    other = described_class.new(company: other_company, customer_name: 'Otro',
                                external_order_id: 'ML-123')
    expect(other).to be_valid
  end

  it 'rejects a company_integration from another company', :aggregate_failures do
    order.company_integration = CompanyIntegration.create!(company: other_company, service: service)
    expect(order).not_to be_valid
    expect(order.errors[:company_integration]).to include('must belong to the same company')
  end

  it 'allows a company_integration from the same company' do
    order.company_integration = CompanyIntegration.create!(company: company, service: service)
    expect(order).to be_valid
  end

  it 'is queryable within a tenant context' do
    Current.company_id = company.id
    expect { described_class.count }.not_to raise_error
  ensure
    Current.reset
  end

  it 'belongs to a company' do
    expect(described_class.reflect_on_association(:company).macro).to eq(:belongs_to)
  end

  it 'belongs to a company_integration as optional', :aggregate_failures do
    expect(described_class.reflect_on_association(:company_integration).macro).to eq(:belongs_to)
    expect(order.company_integration).to be_nil
  end

  it 'has many order_items' do
    expect(described_class.reflect_on_association(:order_items).macro).to eq(:has_many)
  end
end
