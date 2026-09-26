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
                                   credentials: { 'access_token' => 'TOKEN-A' })
        get '/api/v1/integrations', headers: headers
      end

      it 'marks the service as configured and active', :aggregate_failures do
        row = listed.find { |r| r['service_id'] == service.id }
        expect(row['configured']).to be(true)
        expect(row['is_active']).to be(true)
      end

      # Sólo viajan las claves cargadas (`credentials_set`), nunca los valores.
      it 'never exposes the credentials', :aggregate_failures do
        row = listed.find { |r| r['service_id'] == service.id }
        expect(response.body).not_to include('TOKEN-A')
        expect(row).not_to have_key('credentials')
      end
    end

    context 'when only another company configured the service' do
      before do
        CompanyIntegration.create!(company: other_company, service: service,
                                   credentials: { 'access_token' => 'TOKEN-B' })
        get '/api/v1/integrations', headers: headers
      end

      let(:other_company) { Company.create!(name: 'Tenant B', tax_id: '30-22222222-2') }

      it 'shows the service as not configured for the current tenant', :aggregate_failures do
        row = listed.find { |r| r['service_id'] == service.id }
        expect(row['configured']).to be(false)
        expect(row['is_active']).to be(false)
      end
    end
  end

  describe 'PUT /api/v1/integrations/:service_id' do
    it 'returns 401 without a token' do
      put "/api/v1/integrations/#{service.id}", params: payload, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it 'creates the integration for the company of the JWT' do
      expect do
        put "/api/v1/integrations/#{service.id}", params: payload, headers: headers, as: :json
      end.to change(CompanyIntegration, :count).by(1)
    end

    it 'associates the integration to the given service', :aggregate_failures do
      put "/api/v1/integrations/#{service.id}", params: payload, headers: headers, as: :json
      integration = CompanyIntegration.last
      expect(integration.service_id).to eq(service.id)
      expect(integration.company_id).to eq(company.id)
    end

    it 'stores the credentials encrypted at rest' do
      put "/api/v1/integrations/#{service.id}", params: payload, headers: headers, as: :json
      raw = ActiveRecord::Base.connection.select_value(
        "SELECT credentials FROM company_integrations WHERE service_id = #{service.id}"
      )
      expect(raw).not_to include('SECRET-TOKEN')
    end

    # `credentials` tiene que ser un objeto. Un string o un array pasan el
    # `require` —que sólo mira que no venga vacío— y reventarían recién adentro
    # del cifrado, como 500. El guard los corta antes; nadie lo ejercitaba
    # (TESIS-93).
    context 'when credentials is not an object' do
      it 'rejects a string instead of failing inside the encryption' do
        put "/api/v1/integrations/#{service.id}",
            params: { credentials: 'ACCESS-TOKEN' }, headers: headers, as: :json

        expect(response).to have_http_status(:bad_request)
      end

      it 'rejects an array' do
        put "/api/v1/integrations/#{service.id}",
            params: { credentials: ['ACCESS-TOKEN'] }, headers: headers, as: :json

        expect(response).to have_http_status(:bad_request)
      end

      it 'stores nothing' do
        expect do
          put "/api/v1/integrations/#{service.id}",
              params: { credentials: 'ACCESS-TOKEN' }, headers: headers, as: :json
        end.not_to change(CompanyIntegration, :count)
      end
    end

    it 'returns 404 for an unknown service' do
      put '/api/v1/integrations/999999', params: payload, headers: headers, as: :json
      expect(response).to have_http_status(:not_found)
    end

    context 'when the integration already exists' do
      before do
        CompanyIntegration.create!(company: company, service: service,
                                   credentials: { 'access_token' => 'OLD' })
      end

      it 'does not create a duplicate (upsert)' do
        expect do
          put "/api/v1/integrations/#{service.id}", params: payload, headers: headers, as: :json
        end.not_to change(CompanyIntegration, :count)
      end

      it 'overwrites the stored credentials' do
        put "/api/v1/integrations/#{service.id}", params: payload, headers: headers, as: :json
        integration = CompanyIntegration.find_by!(company: company, service: service)
        expect(integration.credentials).to eq('access_token' => 'SECRET-TOKEN')
      end
    end

    # La QA de TESIS-82 encontró que el flag sólo lo aplicaba el front: una
    # empresa sin la feature configuraba integraciones llamando al endpoint.
    context 'when the company does not have the integrations feature' do
      before { company.update!(features: { 'integrations' => false }) }

      it 'refuses to configure the integration', :aggregate_failures do
        expect do
          put "/api/v1/integrations/#{service.id}", params: payload, headers: headers, as: :json
        end.not_to change(CompanyIntegration, :count)
        expect(response).to have_http_status(:forbidden)
      end

      # El widget de nodos del panel lo pide igual, y sólo lista las plantillas
      # globales con el estado de la propia empresa.
      it 'still lists the services' do
        get '/api/v1/integrations', headers: headers

        expect(response).to have_http_status(:ok)
      end
    end

    context 'when another company already configured the same service' do
      let!(:other_integration) do
        CompanyIntegration.create!(
          company: Company.create!(name: 'Tenant B', tax_id: '30-22222222-2'),
          service: service, credentials: { 'access_token' => 'TOKEN-B' }
        )
      end

      it 'creates a new row for the current company' do
        expect do
          put "/api/v1/integrations/#{service.id}", params: payload, headers: headers, as: :json
        end.to change(CompanyIntegration, :count).by(1)
      end

      it 'does not modify the integration of the other company' do
        put "/api/v1/integrations/#{service.id}", params: payload, headers: headers, as: :json
        expect(other_integration.reload.credentials).to eq('access_token' => 'TOKEN-B')
      end
    end
  end

  # Plantillas de operación (TESIS-138): una hija se ejecuta con la cuenta de
  # su madre, así que no se lista ni se conecta por separado.
  describe 'operation templates' do
    let!(:child) do
      Service.create!(service_name: 'Mercado Libre - Conexión', type: 'ecommerce',
                      uri: 'https://api.mercadolibre.com/users/me', http_method: 'GET',
                      parent_service: service, operation: 'connection_test')
    end

    it 'does not list them as connectable services' do
      get '/api/v1/integrations', headers: headers

      expect(listed.pluck('service_id')).to contain_exactly(service.id)
    end

    it 'refuses to connect one directly' do
      put "/api/v1/integrations/#{child.id}", params: payload, headers: headers, as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'settings' do
    it 'stores the non-secret configuration of the account in plain settings' do
      put "/api/v1/integrations/#{service.id}",
          params: payload.merge(settings: { shop_domain: 'demo.myshopify.com' }),
          headers: headers, as: :json

      expect(CompanyIntegration.last.settings).to eq('shop_domain' => 'demo.myshopify.com')
    end

    it 'keeps the stored settings when the request does not send them' do
      CompanyIntegration.create!(company: company, service: service,
                                 credentials: { 'access_token' => 'OLD' },
                                 settings: { 'shop_domain' => 'demo.myshopify.com' })
      put "/api/v1/integrations/#{service.id}", params: payload, headers: headers, as: :json

      expect(CompanyIntegration.last.settings).to eq('shop_domain' => 'demo.myshopify.com')
    end
  end

  describe 'POST /api/v1/integrations/:service_id/test' do
    it 'returns 404 when the company has not configured the service' do
      post "/api/v1/integrations/#{service.id}/test", headers: headers

      expect(response).to have_http_status(:not_found)
    end

    context 'when the company configured the service' do
      before do
        CompanyIntegration.create!(company: company, service: service,
                                   credentials: { 'access_token' => 'TOKEN-A' })
      end

      # Que el proveedor no conteste o rechace la cuenta es el resultado de la
      # prueba, no un error del request.
      it 'answers 200 with the result of the test', :aggregate_failures do
        post "/api/v1/integrations/#{service.id}/test", headers: headers

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body)
          .to eq('ok' => false, 'message' => 'Mercado Libre does not declare a connection test')
      end

      it 'refuses to test without the integrations feature' do
        company.update!(features: { 'integrations' => false })
        post "/api/v1/integrations/#{service.id}/test", headers: headers

        expect(response).to have_http_status(:forbidden)
      end
    end

    it 'does not test the integration of another company' do
      CompanyIntegration.create!(company: Company.create!(name: 'Tenant B', tax_id: '30-22222222-2'),
                                 service: service, credentials: { 'access_token' => 'TOKEN-B' })
      post "/api/v1/integrations/#{service.id}/test", headers: headers

      expect(response).to have_http_status(:not_found)
    end
  end

  # TESIS-138: el formulario de conexión del front se arma con lo que declara
  # la plantilla, y el alta valida contra eso mismo.
  describe 'templates that declare their fields' do
    let!(:shopify) do
      Service.create!(
        service_name: 'Shopify', type: 'ecommerce', http_method: 'POST',
        uri: 'https://:shop_domain/admin/api/2026-07/graphql.json',
        auth_strategy: 'oauth_client_credentials',
        auth_config: { 'token_url' => 'https://:shop_domain/admin/oauth/access_token' },
        credential_fields: [{ 'key' => 'client_id', 'label' => 'Client ID', 'required' => true },
                            { 'key' => 'client_secret', 'label' => 'Secret', 'required' => true }],
        setting_fields: [{ 'key' => 'shop_domain', 'label' => 'Dominio', 'required' => true,
                           'format' => '\A[a-z0-9-]+\.myshopify\.com\z' }]
      )
    end

    def connection
      { credentials: { client_id: 'CID', client_secret: 'shpss_SECRET' },
        settings: { shop_domain: 'demo.myshopify.com' } }
    end

    def shopify_row
      get '/api/v1/integrations', headers: headers
      listed.find { |r| r['service_id'] == shopify.id }
    end

    def connect(body = connection)
      put "/api/v1/integrations/#{shopify.id}", params: body, headers: headers, as: :json
    end

    it 'lists what the connection form has to ask for, without the engine details',
       :aggregate_failures do
      row = shopify_row
      expect(row['credential_fields'].pluck('key')).to eq(%w[client_id client_secret])
      expect(row['setting_fields'].pluck('key')).to eq(%w[shop_domain])
      expect(row).to include('auth_strategy' => 'oauth_client_credentials', 'testable' => true)
      expect(row.keys).not_to include('uri', 'http_method')
    end

    it 'lists the settings and which secrets are loaded, never their values', :aggregate_failures do
      connect
      row = shopify_row
      expect(row['settings']).to eq('shop_domain' => 'demo.myshopify.com')
      expect(row['credentials_set']).to eq(%w[client_id client_secret])
      expect(response.body).not_to include('shpss_SECRET')
    end

    it 'answers 422 with the code of each field that failed', :aggregate_failures do
      connect(credentials: { client_id: 'CID' }, settings: { shop_domain: 'demo.com' })
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq('error' => 'Invalid integration data',
                                         'fields' => failed_fields)
    end

    def failed_fields
      { 'credentials.client_secret' => ['required'], 'settings.shop_domain' => ['invalid_format'] }
    end

    it 'keeps the stored secret when the form leaves it blank' do
      connect
      connect(credentials: { client_id: 'CID', client_secret: '' },
              settings: { shop_domain: 'demo.myshopify.com' })

      expect(CompanyIntegration.last.credentials['client_secret']).to eq('shpss_SECRET')
    end

    it 'does not reactivate a deactivated integration when only its settings change' do
      connect
      CompanyIntegration.last.update!(is_active: false)
      connect(settings: { shop_domain: 'otra.myshopify.com' })

      expect(CompanyIntegration.last.is_active).to be(false)
    end

    describe 'DELETE /api/v1/integrations/:service_id' do
      before do
        connect
        ProductMapping.create!(product: Product.create!(company: company, sku: 'A-1', name: 'A'),
                               company_integration: CompanyIntegration.last,
                               external_product_id: '111')
      end

      it 'disconnects: stops the integration and forgets its secrets', :aggregate_failures do
        delete "/api/v1/integrations/#{shopify.id}", headers: headers

        expect(response).to have_http_status(:no_content)
        expect(CompanyIntegration.last).to have_attributes(is_active: false, credentials: {})
      end

      it 'keeps the settings and the linked products to reconnect later', :aggregate_failures do
        delete "/api/v1/integrations/#{shopify.id}", headers: headers

        expect(CompanyIntegration.last.settings).to eq('shop_domain' => 'demo.myshopify.com')
        expect(ProductMapping.count).to eq(1)
      end

      it 'refuses to disconnect without the integrations feature' do
        company.update!(features: { 'integrations' => false })
        delete "/api/v1/integrations/#{shopify.id}", headers: headers

        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  def payload
    { credentials: { access_token: 'SECRET-TOKEN' } }
  end

  def auth_headers(user)
    post '/api/v1/auth/login', params: { email: user.email, password: 'password123' }, headers: { 'X-Tenant-Slug' => user.company.slug }
    { 'Authorization' => "Bearer #{response.parsed_body['token']}" }
  end
end
