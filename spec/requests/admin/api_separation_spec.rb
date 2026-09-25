# frozen_string_literal: true

require 'rails_helper'

# El backoffice (sesión por cookie, scope admin_user) y la API (JWT, scope
# user) comparten Devise pero no credenciales: ninguna abre la otra puerta.
# Verificado a mano en la QA de TESIS-129; acá queda automatizado.
RSpec.describe 'Backoffice and API sessions', type: :request do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-11111111-1', slug: 'acme') }
  let(:user) { User.create!(email: 'ana@acme.com', password: 'password123', company:) }
  let(:admin_user) { AdminUser.create!(email: 'admin@backoffice.com', password: 'admin123') }

  def api_headers
    post '/api/v1/auth/login', params: { email: user.email, password: 'password123' },
                               headers: { 'X-Tenant-Slug' => company.slug }
    { 'Authorization' => "Bearer #{response.parsed_body['token']}" }
  end

  it 'does not open the backoffice with the JWT of a company user', :aggregate_failures do
    headers = api_headers
    get '/api/v1/me', headers: headers
    expect(response).to have_http_status(:ok)

    get '/admin/resources/companies', headers: headers
    expect(response).to redirect_to('/admin/sign_in')
  end

  it 'does not open the API with the session of the admin', :aggregate_failures do
    post '/admin/sign_in', params: { admin_user: { email: admin_user.email, password: 'admin123' } }
    get '/admin/resources/companies'
    expect(response).to have_http_status(:ok)

    get '/api/v1/me'
    expect(response).to have_http_status(:unauthorized)
  end
end
