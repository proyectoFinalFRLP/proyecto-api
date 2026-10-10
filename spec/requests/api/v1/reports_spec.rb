# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Reports API', type: :request do
  let(:company) { Company.create!(name: 'Tenant A', tax_id: '30-11111111-1') }
  let(:user) { User.create!(email: 'a@example.com', password: 'password123', company: company) }
  let(:headers) { auth_headers(user) }

  def auth_headers(user)
    post '/api/v1/auth/login', params: { email: user.email, password: 'password123' },
                               headers: { 'X-Tenant-Slug' => user.company.slug }
    { 'Authorization' => "Bearer #{response.parsed_body['token']}" }
  end

  def order_of_another_company
    other = Company.create!(name: 'Tenant B', tax_id: '30-22222222-2')
    Current.set(company_id: other.id) do
      Order.create!(company: other, customer_name: 'Otro', total_amount: 9_000, status: 'paid')
    end
  end

  describe 'GET /api/v1/reports/overview' do
    it 'returns 401 without a token' do
      get '/api/v1/reports/overview'

      expect(response).to have_http_status(:unauthorized)
    end

    it 'answers the overview of the last seven days by default', :aggregate_failures do
      get '/api/v1/reports/overview', headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['period']).to eq('7d')
      expect(response.parsed_body['curve'].size).to eq(7)
    end

    # Un recurso viaja pelado (ADR-015): sin `data` ni `meta`.
    it 'answers a bare resource with the agreed keys', :aggregate_failures do
      get '/api/v1/reports/overview', params: { period: '30d' }, headers: headers

      expect(response.parsed_body.keys)
        .to match_array(%w[period from to granularity kpis curve carriers])
      expect(response.parsed_body['kpis'].keys)
        .to match_array(%w[orders revenue dispatched_units on_time_delivery_rate active_anomalies])
    end

    it 'counts the orders of the tenant of the token' do
      Order.create!(company: company, customer_name: 'Cliente', total_amount: 1_200, status: 'paid')

      get '/api/v1/reports/overview', headers: headers

      expect(response.parsed_body.dig('kpis', 'revenue', 'value')).to eq(1_200.0)
    end

    it 'never adds up the orders of another company' do
      order_of_another_company

      get '/api/v1/reports/overview', headers: headers

      expect(response.parsed_body.dig('kpis', 'revenue', 'value')).to eq(0.0)
    end

    it 'returns 400 for a period it does not know', :aggregate_failures do
      get '/api/v1/reports/overview', params: { period: '1y' }, headers: headers

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['error']).to eq('period must be one of 7d, 30d, 90d')
    end

    it 'returns 400 when the period comes as a list' do
      get '/api/v1/reports/overview', params: { period: ['7d'] }, headers: headers

      expect(response).to have_http_status(:bad_request)
    end
  end
end
