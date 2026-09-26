# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Integrations API', type: :request do
  let(:company) do
    Company.create!(name: 'Tenant A', tax_id: '30-11111111-1', features: { 'integrations' => true })
  end
  let(:user) { User.create!(email: 'a@example.com', password: 'password123', company: company) }
  let(:headers) { auth_headers(user) }
  let!(:service) do
    Service.create!(service_name: 'Mercado Libre', type: 'ecommerce',
                    uri: 'https://api.mercadolibre.com', http_method: 'GET')
  end

  # El listado viaja envuelto en `data`, como todas las colecciones (ADR-015).
  def listed
    response.parsed_body['data']
  end

  def row_for(service)
    get '/api/v1/integrations', headers: headers
    listed.find { |r| r['service_id'] == service.id }
  end

  describe 'GET /api/v1/integrations' do
    it 'returns 401 without a token' do
      get '/api/v1/integrations'
      expect(response).to have_http_status(:unauthorized)
    end

    # Era el único listado que contestaba un array pelado. Un array en la raíz
    # no deja lugar para `meta` sin romper a quien lo consume, y obligaba al
    # front a recordar que éste es la excepción (ADR-015, TESIS-107).
    it 'wraps the collection in data and meta, like every other listing' do
      get '/api/v1/integrations', headers: headers

      expect(response.parsed_body.keys).to match_array(%w[data meta])
    end

    context 'when the company has the service configured' do
      before do
        CompanyIntegration.create!(company: company, service: service,
                                   credentials: { 'access_token' => 'TOKEN-A' },
                                   settings: { 'account_name' => 'Tienda Norte' })
      end

      it 'marks the service as configured and active', :aggregate_failures do
        row = row_for(service)
        expect(row['configured']).to be(true)
        expect(row['is_active']).to be(true)
      end

      it 'says which account is connected' do
        expect(row_for(service)['account_name']).to eq('Tienda Norte')
      end

      it 'never exposes the credentials', :aggregate_failures do
        row = row_for(service)
        expect(response.body).not_to include('TOKEN-A')
        expect(row).not_to have_key('credentials')
      end

      # La pantalla sólo muestra el estado: el formulario de conexión vive en
      # el backoffice (ADR-018), así que ni los detalles del motor ni lo que
      # pide la plantilla tienen por qué viajar.
      it 'lists only the status, without the engine or the connection form', :aggregate_failures do
        row = row_for(service)
        expect(row.keys).to match_array(
          %w[service_id service_name type configured is_active integration_id account_name]
        )
      end
    end

    context 'when only another company configured the service' do
      before do
        CompanyIntegration.create!(company: other_company, service: service,
                                   credentials: { 'access_token' => 'TOKEN-B' })
      end

      let(:other_company) { Company.create!(name: 'Tenant B', tax_id: '30-22222222-2') }

      it 'shows the service as not configured for the current tenant', :aggregate_failures do
        row = row_for(service)
        expect(row['configured']).to be(false)
        expect(row['is_active']).to be(false)
        expect(row['account_name']).to be_nil
      end
    end

    # El widget de nodos del panel lo pide igual, y sólo lista las plantillas
    # globales con el estado de la propia empresa.
    it 'lists the services even without the integrations feature' do
      company.update!(features: { 'integrations' => false })
      get '/api/v1/integrations', headers: headers

      expect(response).to have_http_status(:ok)
    end
  end

  # Plantillas de operación (TESIS-138): una hija se ejecuta con la cuenta de
  # su madre, así que no se lista por separado.
  describe 'operation templates' do
    before do
      Service.create!(service_name: 'Mercado Libre - Conexión', type: 'ecommerce',
                      uri: 'https://api.mercadolibre.com/users/me', http_method: 'GET',
                      parent_service: service, operation: 'connection_test')
    end

    it 'does not list them as connectable services' do
      get '/api/v1/integrations', headers: headers

      expect(listed.pluck('service_id')).to contain_exactly(service.id)
    end
  end

  # Las credenciales las carga el equipo de OneStock desde el backoffice
  # (ADR-018). La empresa no tiene cómo cargarlas, cambiarlas ni probarlas: si
  # quedara el endpoint, podría hacerlo con Postman aunque el front no lo ofrezca.
  describe 'loading a connection' do
    before do
      CompanyIntegration.create!(company: company, service: service,
                                 credentials: { 'access_token' => 'TOKEN-A' })
    end

    it 'cannot be created or changed', :aggregate_failures do
      put "/api/v1/integrations/#{service.id}", headers: headers, as: :json,
                                                params: { credentials: { access_token: 'OTRO' } }

      expect(response).to have_http_status(:not_found)
      expect(CompanyIntegration.last.credentials).to eq('access_token' => 'TOKEN-A')
    end

    it 'cannot be disconnected' do
      delete "/api/v1/integrations/#{service.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it 'cannot be tested' do
      post "/api/v1/integrations/#{service.id}/test", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  def auth_headers(user)
    post '/api/v1/auth/login', params: { email: user.email, password: 'password123' },
                               headers: { 'X-Tenant-Slug' => user.company.slug }
    { 'Authorization' => "Bearer #{response.parsed_body['token']}" }
  end
end
