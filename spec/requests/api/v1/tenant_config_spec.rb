require 'rails_helper'

RSpec.describe 'Tenant config API', type: :request do
  let(:norte) do
    Company.create!(
      name: 'Distribuidora Norte',
      tax_id: '30-11111111-1',
      slug: 'norte',
      features: { 'integrations' => true },
      branding: {
        'display_name' => 'Distribuidora Norte',
        'primary_color' => '#2E7D32',
        'accent_color' => '#66BB6A',
        'logo_url' => nil,
        'tagline' => 'Logística del norte'
      }
    )
  end

  let(:sur) do
    Company.create!(
      name: 'Comercial Sur',
      tax_id: '30-22222222-2',
      slug: 'sur',
      features: { 'integrations' => false },
      branding: { 'display_name' => 'Comercial Sur', 'primary_color' => '#1565C0' }
    )
  end

  describe 'GET /api/v1/tenant-config without a JWT' do
    it 'resolves the tenant from the query param', :aggregate_failures do
      get '/api/v1/tenant-config', params: { slug: sur.slug }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['slug']).to eq('sur')
    end

    it 'resolves the tenant from the X-Tenant-Slug header', :aggregate_failures do
      get '/api/v1/tenant-config', headers: { 'X-Tenant-Slug' => norte.slug }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['slug']).to eq('norte')
    end

    # El contrato con el frontend: snake_case, sin envoltorio `data`.
    it 'returns the tenant unwrapped, with its features', :aggregate_failures do
      get '/api/v1/tenant-config', headers: { 'X-Tenant-Slug' => norte.slug }
      body = response.parsed_body

      expect(body).not_to have_key('data')
      expect(body['name']).to eq('Distribuidora Norte')
      expect(body['features']).to eq({ 'integrations' => true })
    end

    it 'returns the branding tokens in snake_case' do
      get '/api/v1/tenant-config', headers: { 'X-Tenant-Slug' => norte.slug }

      expect(response.parsed_body['branding']).to include('display_name' => 'Distribuidora Norte', 'primary_color' => '#2E7D32', 'logo_url' => nil)
    end

    # La config es pública: no puede filtrar el id del tenant.
    it 'does not expose the company id' do
      get '/api/v1/tenant-config', headers: { 'X-Tenant-Slug' => norte.slug }

      expect(response.parsed_body.keys).not_to include('company_id', 'id')
    end

    it 'returns 404 for an unknown slug' do
      get '/api/v1/tenant-config', headers: { 'X-Tenant-Slug' => 'no-existe' }

      expect(response).to have_http_status(:not_found)
    end

    # Una empresa dada de baja se trata como inexistente, no como prohibida.
    it 'returns 404 for an inactive company' do
      inactive = Company.create!(name: 'Importadora Vieja', tax_id: '30-33333333-3', slug: 'importadora', is_active: false)

      get '/api/v1/tenant-config', headers: { 'X-Tenant-Slug' => inactive.slug }

      expect(response).to have_http_status(:not_found)
    end

    it 'returns 404 when no slug is sent at all' do
      get '/api/v1/tenant-config'

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'GET /api/v1/tenant-config with a valid JWT' do
    let(:token) do
      User.create!(email: 'admin@norte.com', password: 'password123', company: norte)
      post '/api/v1/auth/login',
           params: { email: 'admin@norte.com', password: 'password123' },
           headers: { 'X-Tenant-Slug' => norte.slug }
      response.parsed_body['token']
    end

    let(:auth) { { 'Authorization' => "Bearer #{token}" } }

    it 'resolves the tenant from the JWT' do
      get '/api/v1/tenant-config', headers: auth

      expect(response.parsed_body['slug']).to eq('norte')
    end

    # La regla dura de la ADR-003: con JWT presente, el header no puede mover el
    # tenant. Si el slug ganara acá, el header sería una fuente de aislamiento.
    it 'ignores the slug header and answers with the JWT tenant', :aggregate_failures do
      sur

      get '/api/v1/tenant-config', headers: auth.merge('X-Tenant-Slug' => 'sur')

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['slug']).to eq('norte')
    end

    it 'ignores the slug query param too' do
      sur

      get '/api/v1/tenant-config', params: { slug: 'sur' }, headers: auth

      expect(response.parsed_body['slug']).to eq('norte')
    end
  end

  # Un token ilegible no es una credencial: el endpoint es público, así que
  # degrada al slug en vez de responder 401.
  describe 'GET /api/v1/tenant-config with an invalid JWT' do
    it 'falls back to the slug' do
      get '/api/v1/tenant-config',
          headers: { 'Authorization' => 'Bearer no-es-un-token', 'X-Tenant-Slug' => sur.slug }

      expect(response.parsed_body['slug']).to eq('sur')
    end
  end
end
