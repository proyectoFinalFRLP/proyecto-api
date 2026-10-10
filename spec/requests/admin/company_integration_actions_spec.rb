# frozen_string_literal: true

require 'rails_helper'

# Las credenciales de una empresa las carga el equipo de OneStock desde el
# backoffice (ADR-018), con un campo por cada dato que declara la plantilla.
RSpec.describe 'Admin company integration actions (Avo)', type: :request do
  let(:admin_user) { AdminUser.create!(email: 'admin@backoffice.com', password: 'admin123') }
  let(:shopify) do
    Service.create!(
      service_name: 'Shopify', type: 'ecommerce', http_method: 'POST',
      uri: 'https://:shop_domain/admin/api/2026-07/graphql.json', request_format: 'graphql',
      auth_strategy: 'oauth_client_credentials',
      auth_config: { 'token_url' => 'https://:shop_domain/admin/oauth/access_token',
                     'token_header' => 'X-Shopify-Access-Token', 'token_prefix' => '' },
      credential_fields: [{ 'key' => 'client_id', 'label' => 'Client ID', 'required' => true },
                          { 'key' => 'client_secret', 'label' => 'Client secret',
                            'required' => true }],
      setting_fields: [{ 'key' => 'shop_domain', 'label' => 'Shop domain', 'required' => true,
                         'format' => '\A[a-z0-9-]+\.myshopify\.com\z' },
                       { 'key' => 'location_id', 'label' => 'Location' }]
    )
  end
  let!(:integration) do
    CompanyIntegration.create!(
      company: Company.create!(name: 'Acme', tax_id: '20-11111111-1', slug: 'acme'),
      service: shopify, is_active: false,
      settings: { 'shop_domain' => 'demo.myshopify.com' },
      credentials: { 'client_id' => 'CID', 'client_secret' => 'shpss_STORED',
                     'access_token' => 'CACHED', 'token_expires_at' => 1.hour.from_now.iso8601 }
    )
  end

  before { sign_in admin_user }

  def record_path = "/admin/resources/company_integrations/#{integration.id}"

  def open_action(action)
    get "#{record_path}/actions", params: { action_id: action }
  end

  def run_action(action, fields = {})
    post "#{record_path}/actions", headers: { 'Accept' => 'text/vnd.turbo-stream.html' }, params: {
      action_id: action, fields: fields.merge(avo_resource_ids: integration.id.to_s)
    }
  end

  describe 'Configure connection' do
    def action = 'Avo::Actions::ConfigureConnection'

    it 'asks for each declared field without showing the stored secrets', :aggregate_failures do
      open_action(action)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Client ID', 'Client secret', 'Shop domain')
      expect(response.body).to include('demo.myshopify.com')
      expect(response.body).not_to include('shpss_STORED', 'CACHED')
    end

    context 'with valid data' do
      before do
        stub_request(:post, 'https://otra.myshopify.com/admin/oauth/access_token')
          .to_return(status: 200, headers: { 'Content-Type' => 'application/json' },
                     body: { access_token: 'NEW-TOKEN', expires_in: 86_399 }.to_json)
        run_action(action, credentials__client_id: '', credentials__client_secret: 'shpss_NEW',
                           settings__shop_domain: 'otra.myshopify.com', settings__location_id: '')
      end

      it 'stores the new secret and keeps the one left blank', :aggregate_failures do
        credentials = integration.reload.credentials
        expect(credentials['client_id']).to eq('CID')
        expect(credentials['client_secret']).to eq('shpss_NEW')
      end

      it 'stores the settings' do
        expect(integration.reload.settings['shop_domain']).to eq('otra.myshopify.com')
      end

      # Sin plantilla de prueba, probar la conexión es obtener el token: se pide
      # con las credenciales nuevas, no con el que estaba cacheado.
      it 'tests the connection with the new account' do
        expect(integration.reload.credentials['access_token']).to eq('NEW-TOKEN')
      end

      it 'does not activate the integration on its own' do
        expect(integration.reload.is_active).to be(false)
      end
    end

    it 'rejects a field that does not match the declared format', :aggregate_failures do
      run_action(action, credentials__client_secret: '', settings__shop_domain: 'no es un dominio')

      expect(response.body).to include('Shop domain: invalid_format')
      expect(integration.reload.settings['shop_domain']).to eq('demo.myshopify.com')
    end
  end

  describe 'Test connection' do
    before do
      stub_request(:post, 'https://demo.myshopify.com/admin/oauth/access_token')
        .to_return(status: 401)
      integration.update!(credentials: integration.credentials.except('access_token'))
      run_action('Avo::Actions::TestConnection')
    end

    # El resultado se muestra como aviso al recargar el detalle.
    it 'reports what the provider answered' do
      expect(flash[:error][:body]).to include('HTTP 401')
    end

    it 'keeps the stored account' do
      expect(integration.reload.credentials['client_secret']).to eq('shpss_STORED')
    end
  end
end
