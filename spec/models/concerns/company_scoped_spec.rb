# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CompanyScoped, type: :model do
  let(:company_a) { Company.create!(name: 'Tenant A', tax_id: '30-11111111-1') }
  let(:company_b) { Company.create!(name: 'Tenant B', tax_id: '30-22222222-2') }
  let!(:warehouse_a) do
    Warehouse.create!(name: 'Depo A', zip_code: '1900', address: 'Calle 1', company: company_a)
  end
  let!(:warehouse_b) do
    Warehouse.create!(name: 'Depo B', zip_code: '8000', address: 'Calle 2', company: company_b)
  end

  after { Current.reset }

  describe 'default scope' do
    it 'returns only the records of the current tenant' do
      Current.company_id = company_a.id
      expect(Warehouse.all).to contain_exactly(warehouse_a)
    end

    it 'raises RecordNotFound when finding a record of another tenant by id' do
      Current.company_id = company_a.id
      expect { Warehouse.find(warehouse_b.id) }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it 'returns every record when no tenant context is set' do
      expect(Warehouse.all).to contain_exactly(warehouse_a, warehouse_b)
    end

    it 'allows background workers to bypass the scope with unscoped' do
      Current.company_id = company_a.id
      expect(Warehouse.unscoped).to contain_exactly(warehouse_a, warehouse_b)
    end
  end

  describe 'company assignment on create' do
    it 'ignores a company_id provided in the payload and injects the current tenant' do
      Current.company_id = company_a.id
      warehouse = Warehouse.create!(name: 'Nuevo', zip_code: '1000', address: 'Calle 3',
                                    company_id: company_b.id)
      expect(warehouse.company_id).to eq(company_a.id)
    end

    it 'keeps the explicit company_id when no tenant context is set' do
      warehouse = Warehouse.create!(name: 'Seed', zip_code: '1000', address: 'Calle 4',
                                    company_id: company_b.id)
      expect(warehouse.company_id).to eq(company_b.id)
    end
  end
end
