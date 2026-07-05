require 'rails_helper'

RSpec.describe 'Auth API', type: :request do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-11111111-1') }

  describe 'POST /api/v1/auth/register' do
    let(:valid_params) { { email: 'new@test.com', password: 'password123', company_id: company.id } }

    it 'creates a user', :aggregate_failures do
      expect { post '/api/v1/auth/register', params: valid_params }.to change(User, :count).by(1)
      expect(response).to have_http_status(:created)
    end

    it 'returns the user without exposing the password', :aggregate_failures do
      post '/api/v1/auth/register', params: valid_params
      body = response.parsed_body
      expect(body['email']).to eq('new@test.com')
      expect(body.keys).not_to include('password', 'encrypted_password')
    end

    it 'stores the password hashed, never in plain text', :aggregate_failures do
      post '/api/v1/auth/register', params: valid_params
      expect(User.last.encrypted_password).to be_present
      expect(User.last.encrypted_password).not_to eq('password123')
    end

    it 'rejects a duplicate email' do
      User.create!(email: 'dup@test.com', password: 'password123', company: company)
      post '/api/v1/auth/register', params: valid_params.merge(email: 'dup@test.com')
      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'rejects a non-existent company' do
      post '/api/v1/auth/register', params: valid_params.merge(company_id: -1)
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe 'POST /api/v1/auth/login' do
    before { User.create!(email: 'log@test.com', password: 'password123', company: company) }

    it 'returns a JWT with user_id and company_id', :aggregate_failures do
      post '/api/v1/auth/login', params: { email: 'log@test.com', password: 'password123' }
      payload = decode_jwt(response.parsed_body['token'])
      expect(payload['user_id']).to eq(User.last.id)
      expect(payload['company_id']).to eq(company.id)
    end

    it 'returns 401 on wrong password' do
      post '/api/v1/auth/login', params: { email: 'log@test.com', password: 'wrong' }
      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns 401 on unknown email' do
      post '/api/v1/auth/login', params: { email: 'ghost@test.com', password: 'password123' }
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
