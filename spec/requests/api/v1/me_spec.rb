# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Me API', type: :request do
  let(:company) { Company.create!(name: 'Acme', tax_id: '30-11111111-1') }
  let(:user) { User.create!(email: 'me@example.com', password: 'password123', company: company) }

  def token_for(user)
    post '/api/v1/auth/login', params: { email: user.email, password: 'password123' }, headers: { 'X-Tenant-Slug' => user.company.slug }
    response.parsed_body['token']
  end

  def auth_headers(user)
    { 'Authorization' => "Bearer #{token_for(user)}" }
  end

  describe 'GET /api/v1/me' do
    it 'returns 401 without a token' do
      get '/api/v1/me'
      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns 401 with a malformed token' do
      get '/api/v1/me', headers: { 'Authorization' => 'Bearer not-a-jwt' }
      expect(response).to have_http_status(:unauthorized)
    end

    context 'when authenticated' do
      before { get '/api/v1/me', headers: auth_headers(user) }

      it 'returns the user of the token' do
        expect(response).to have_http_status(:ok)
      end

      it 'returns the email as the API has it stored, not as it was typed' do
        expect(response.parsed_body['email']).to eq('me@example.com')
      end

      it 'returns the company with its name, which does not travel in the JWT', :aggregate_failures do
        expect(response.parsed_body['company']).to eq('id' => company.id, 'name' => 'Acme')
        expect(response.parsed_body['company_id']).to eq(company.id)
      end

      it 'never exposes the password digest' do
        expect(response.parsed_body.keys).not_to include('password', 'encrypted_password')
      end
    end

    it 'returns the caller of each token, not the first user of the company', :aggregate_failures do
      other = User.create!(email: 'other@example.com', password: 'password123', company: company)

      get '/api/v1/me', headers: auth_headers(user)
      expect(response.parsed_body['id']).to eq(user.id)

      get '/api/v1/me', headers: auth_headers(other)
      expect(response.parsed_body['id']).to eq(other.id)
    end

    context 'when the caller belongs to another tenant' do
      let(:rival) { Company.create!(name: 'Rival', tax_id: '30-22222222-2') }
      let(:stranger) do
        # Current.company_id puede quedar del request anterior y pisaría el
        # company: manual (CompanyScoped#assign_current_company).
        Current.set(company_id: nil) do
          User.create!(email: 'stranger@rival.com', password: 'password123', company: rival)
        end
      end

      it 'returns their own company, not the one of the previous request' do
        get '/api/v1/me', headers: auth_headers(stranger)

        expect(response.parsed_body['company']).to eq('id' => rival.id, 'name' => 'Rival')
      end
    end

    # El token sigue siendo criptográficamente válido después de borrar al
    # usuario: lo que falla es la búsqueda. Sin este caso, el hallazgo llega
    # como un 500 en producción.
    it 'returns 401 when the token belongs to a user that no longer exists' do
      headers = auth_headers(user)
      Current.set(company_id: nil) { user.destroy! }

      get '/api/v1/me', headers: headers

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
