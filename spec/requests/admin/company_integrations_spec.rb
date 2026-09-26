# frozen_string_literal: true

require 'rails_helper'

# Las credenciales de las integraciones son API keys y tokens de las cuentas de
# cada empresa. El backoffice las mostraba descifradas en el detalle y en el
# formulario (QA de TESIS-129, hallazgo 2); ahora sólo dice qué claves hay.
RSpec.describe 'Admin company integrations (Avo)', type: :request do
  let(:admin_user) { AdminUser.create!(email: 'admin@backoffice.com', password: 'admin123') }
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-11111111-1', slug: 'acme') }
  let(:service) do
    Service.create!(service_name: 'Mercado Libre', type: 'ecommerce',
                    uri: 'https://api.mercadolibre.com', http_method: 'GET')
  end
  let!(:integration) do
    CompanyIntegration.create!(company:, service:,
                               credentials: { 'access_token' => 'APP_USR-secret-123' })
  end
  let(:integration_path) { "/admin/resources/company_integrations/#{integration.id}" }

  before { sign_in admin_user }

  describe 'GET show' do
    it 'does not show the value of the credentials', :aggregate_failures do
      get integration_path

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('APP_USR-secret-123')
    end

    it 'shows which credentials are configured', :aggregate_failures do
      get integration_path

      expect(response.body).to include('access_token')
      expect(response.body).to include('••••••')
    end

    # Editarlas desde el backoffice las guardaba como String (el campo de código
    # manda texto). Una fila así se enmascara entera en vez de romper la página.
    it 'masks credentials that were stored as a string', :aggregate_failures do
      integration.update!(credentials: '{"access_token": "stored-as-string"}')
      get integration_path

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('stored-as-string')
    end
  end

  describe 'GET edit' do
    it 'has no field for the credentials', :aggregate_failures do
      get "#{integration_path}/edit"

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('company_integration[credentials]')
    end
  end

  describe 'PATCH' do
    it 'does not change the credentials', :aggregate_failures do
      patch integration_path, params: { company_integration: {
        is_active: '0', credentials: '{"access_token": "otro"}'
      } }

      expect(integration.reload.is_active).to be(false)
      expect(integration.credentials).to eq('access_token' => 'APP_USR-secret-123')
    end
  end
end
