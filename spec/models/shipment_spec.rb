# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Shipment, type: :model do
  subject(:shipment) do
    described_class.new(company: company, order: order)
  end

  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:other_company) { Company.create!(name: 'Other Corp', tax_id: '30-99999999-9') }
  let(:order) { Order.create!(company: company, customer_name: 'Cliente ACME') }
  let(:service) do
    Service.create!(service_name: 'Andreani', type: 'courier',
                    uri: 'https://apis.andreani.com', http_method: 'POST')
  end

  it 'is valid with required attributes' do
    expect(shipment).to be_valid
  end

  it 'defaults status to pending' do
    shipment.save!
    expect(shipment.status).to eq('pending')
  end

  it 'is invalid without a company' do
    shipment.company = nil
    expect(shipment).not_to be_valid
  end

  it 'is invalid without an order' do
    shipment.order = nil
    expect(shipment).not_to be_valid
  end

  it 'accepts only valid statuses' do
    described_class::STATUSES.each do |status|
      shipment.status = status
      expect(shipment).to be_valid
    end
  end

  it 'rejects an unknown status' do
    shipment.status = 'lost'
    expect(shipment).not_to be_valid
  end

  it 'enforces one shipment per order (model validation)', :aggregate_failures do
    shipment.save!
    duplicate = described_class.new(company: company, order: order)
    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:order_id]).to include('has already been taken')
  end

  it 'enforces one shipment per order at the database level' do
    shipment.save!
    duplicate = described_class.new(company: company, order: order)
    expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it 'allows shipments for different orders' do
    other_order = Order.create!(company: company, customer_name: 'Otro Cliente')
    described_class.create!(company: company, order: order)
    second = described_class.new(company: company, order: other_order)
    expect(second).to be_valid
  end

  it 'rejects an order from another company', :aggregate_failures do
    shipment.order = Order.create!(company: other_company, customer_name: 'Orden Ajena')
    expect(shipment).not_to be_valid
    expect(shipment.errors[:base]).to include('order must belong to the same company as the shipment')
  end

  it 'rejects a company_integration from another company', :aggregate_failures do
    shipment.company_integration = CompanyIntegration.create!(company: other_company, service: service)
    expect(shipment).not_to be_valid
    expect(shipment.errors[:company_integration]).to include('must belong to the same company')
  end

  it 'allows a company_integration from the same company' do
    shipment.company_integration = CompanyIntegration.create!(company: company, service: service)
    expect(shipment).to be_valid
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

  it 'belongs to an order' do
    expect(described_class.reflect_on_association(:order).macro).to eq(:belongs_to)
  end

  it 'belongs to a company_integration as optional', :aggregate_failures do
    expect(described_class.reflect_on_association(:company_integration).macro).to eq(:belongs_to)
    expect(shipment.company_integration).to be_nil
  end

  it 'has many shipment_events' do
    expect(described_class.reflect_on_association(:shipment_events).macro).to eq(:has_many)
  end
end
