# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Integrations API', type: :request do
  let(:company) { Company.create!(name: 'Tenant A', tax_id: '30-11111111-1') }
  let(:user) { User.create!(email: 'a@example.com', password: 'password123', company: company) }
  let(:headers) { auth_headers(user) }
  let!(:service) do
    Service.create!(service_name: 'Mercado Libre', type: 'ecommerce',
                    uri: 'https://api.mercadolibre.com', http_method: 'GET')
  end

  describe 'GET /api/v1/integrations' do
    it 'returns 401 without a token' do
      get '/api/v1/integrations'
      expect(response).to have_http_status(:unauthorized)
    end

    context 'when the company has the service configured' do
      before do
        CompanyIntegration.create!(company: company, service: service,
                                   credentials: { 'access_token' => 'TOKEN-A' })
        get '/api/v1/integrations', headers: headers
      end

      it 'marks the service as configured and active', :aggregate_failures do
        row = response.parsed_body.find { |r| r['service_id'] == service.id }
        expect(row['configured']).to be(true)
        expect(row['is_active']).to be(true)
      end

      it 'never exposes the credentials' do
        expect(response.body).not_to include('TOKEN-A', 'credentials')
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
        row = response.parsed_body.find { |r| r['service_id'] == service.id }
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

  def payload
    { credentials: { access_token: 'SECRET-TOKEN' } }
  end

  def auth_headers(user)
    post '/api/v1/auth/login', params: { email: user.email, password: 'password123' }
    { 'Authorization' => "Bearer #{response.parsed_body['token']}" }
  end
end
