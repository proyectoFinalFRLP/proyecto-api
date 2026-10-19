# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/seeds/oca').to_s

# La conexión de demo de OCA que siembran los seeds en desarrollo (TESIS-186):
# cualquiera que levante el proyecto tiene el flujo de OCA andando sin cargar
# nada, y nadie pierde la cuenta propia que conectó con la tarea.
RSpec.describe OcaSeeds do
  let(:company) { Company.create!(name: 'Norte', tax_id: '30-11111111-1') }

  let(:oca) { Service.find_by!(service_name: 'OCA') }
  let(:own_credentials) { { 'usr' => 'mia@empresa.com', 'psw' => 'secreta' } }
  let(:own_settings) do
    { 'cuit' => '30-71234567-8', 'nrocuenta' => '222222/001', 'operativa' => '11111',
      'centrocosto' => '2' }
  end

  before { described_class.install! }

  def integration_for(service_name)
    CompanyIntegration.joins(:service)
                      .find_by(company: company, services: { service_name: service_name })
  end

  describe '.connect_demo!' do
    it 'connects the company to dispatch with the public test account', :aggregate_failures do
      described_class.connect_demo!(company)

      dispatch = integration_for('OCA')
      expect(dispatch).to be_is_active
      expect(dispatch.credentials).to eq('usr' => 'test@oca.com.ar', 'psw' => '123456')
      expect(dispatch.settings).to include('nrocuenta' => '111757/001', 'operativa' => '64665')
    end

    it 'connects the company to quote with the CUIT and the operativa' do
      described_class.connect_demo!(company)

      expect(integration_for('OCA - Cotización').settings)
        .to eq('cuit' => '30-53625919-4', 'operativa' => '64665')
    end

    it 'can run again without duplicating the integrations' do
      2.times { described_class.connect_demo!(company) }

      expect(CompanyIntegration.where(company: company).count).to eq(2)
    end

    it 'keeps an account the company connected on its own' do
      own = Integrations::UpsertIntegration.new(company: company, service_id: oca.id, settings: own_settings,
                                                credentials: own_credentials).call

      described_class.connect_demo!(company)

      expect(own.reload.credentials).to eq(own_credentials)
    end
  end
end
