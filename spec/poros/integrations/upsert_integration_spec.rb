# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Integrations::UpsertIntegration, type: :poro do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:service) do
    Service.create!(service_name: 'Andreani', type: 'courier',
                    uri: 'https://api.andreani.com', http_method: 'POST')
  end

  describe '#call' do
    it 'creates the integration when it does not exist' do
      expect do
        described_class.new(company: company, service_id: service.id,
                            credentials: { 'k' => 'v' }).call
      end.to change(CompanyIntegration, :count).by(1)
    end

    it 'stores the given credentials' do
      integration = described_class.new(company: company, service_id: service.id,
                                        credentials: { 'k' => 'v' }).call
      expect(integration.credentials).to eq('k' => 'v')
    end

    it 'defaults is_active to true when not provided' do
      integration = described_class.new(company: company, service_id: service.id,
                                        credentials: {}).call
      expect(integration.is_active).to be(true)
    end

    it 'raises RecordNotFound for an unknown service' do
      poro = described_class.new(company: company, service_id: 0, credentials: {})
      expect { poro.call }.to raise_error(ActiveRecord::RecordNotFound)
    end

    context 'when the integration already exists' do
      before do
        CompanyIntegration.create!(company: company, service: service,
                                   credentials: { 'k' => 'old' })
      end

      it 'does not create a duplicate' do
        expect do
          described_class.new(company: company, service_id: service.id,
                              credentials: { 'k' => 'new' }).call
        end.not_to change(CompanyIntegration, :count)
      end

      it 'updates the credentials' do
        integration = described_class.new(company: company, service_id: service.id,
                                          credentials: { 'k' => 'new' }).call
        expect(integration.credentials).to eq('k' => 'new')
      end
    end
  end
end
