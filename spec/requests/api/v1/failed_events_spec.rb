# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Failed events API', type: :request do
  let(:company) { Company.create!(name: 'Tenant A', tax_id: '30-11111111-1') }
  let(:user) { User.create!(email: 'a@example.com', password: 'password123', company: company) }
  let(:headers) { auth_headers(user) }
  let(:other_company) { Company.create!(name: 'Tenant B', tax_id: '30-22222222-2') }
  let!(:event) { create_event(company, status: :dead, attempts: 5) }

  describe 'GET /api/v1/failed-events' do
    it 'returns 401 without a token' do
      get '/api/v1/failed-events'

      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns the events of the authenticated company' do
      get '/api/v1/failed-events', headers: headers

      expect(response.parsed_body.pluck('id')).to contain_exactly(event.id)
    end

    it 'never returns events of another company' do
      create_event(other_company)
      get '/api/v1/failed-events', headers: headers

      expect(response.parsed_body.size).to eq(1)
    end

    it 'filters by status' do
      pending_event = create_event(company, status: :pending)
      get '/api/v1/failed-events', params: { status: 'pending' }, headers: headers

      expect(response.parsed_body.pluck('id')).to contain_exactly(pending_event.id)
    end

    it 'ignores an unknown status filter' do
      get '/api/v1/failed-events', params: { status: 'exploded' }, headers: headers

      expect(response).to have_http_status(:ok)
    end

    it 'never exposes the stored payload nor the response body' do
      event.update!(payload: { 'secret' => 'CUSTOMER-DATA' }, last_response_body: 'RAW-BODY')
      get '/api/v1/failed-events', headers: headers

      expect(response.body).not_to include('CUSTOMER-DATA', 'RAW-BODY')
    end
  end

  describe 'POST /api/v1/failed-events/:id/retry' do
    it 'brings the event back to the queue', :aggregate_failures do
      post "/api/v1/failed-events/#{event.id}/retry", headers: headers

      expect(response).to have_http_status(:ok)
      expect(event.reload).to have_attributes(status: 'pending', attempts: 0)
    end

    it 'enqueues the retry job' do
      expect { post "/api/v1/failed-events/#{event.id}/retry", headers: headers }
        .to have_enqueued_job(Webhooks::RetryFailedEventJob).with(event.id, company.id)
    end

    it 'returns 422 when the event is already being processed' do
      event.update!(status: :processing)
      post "/api/v1/failed-events/#{event.id}/retry", headers: headers

      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'returns 404 for an event of another company' do
      foreign = create_event(other_company)
      post "/api/v1/failed-events/#{foreign.id}/retry", headers: headers

      expect(response).to have_http_status(:not_found)
    end

    it 'does not touch the event of another company' do
      foreign = create_event(other_company)
      post "/api/v1/failed-events/#{foreign.id}/retry", headers: headers

      expect(foreign.reload.status).to eq('pending')
    end
  end

  describe 'POST /api/v1/failed-events/:id/discard' do
    it 'takes the event out of the retry cycle', :aggregate_failures do
      post "/api/v1/failed-events/#{event.id}/discard", headers: headers

      expect(response).to have_http_status(:ok)
      expect(event.reload).to have_attributes(status: 'discarded', next_retry_at: nil)
    end

    it 'returns 404 for an event of another company' do
      foreign = create_event(other_company)
      post "/api/v1/failed-events/#{foreign.id}/discard", headers: headers

      expect(response).to have_http_status(:not_found)
    end
  end

  def create_event(owner, attributes = {})
    FailedEvent.create!({ company: owner, event_type: 'integrations.http_request',
                          next_retry_at: 1.minute.from_now }.merge(attributes))
  end

  def auth_headers(user)
    post '/api/v1/auth/login', params: { email: user.email, password: 'password123' }
    { 'Authorization' => "Bearer #{response.parsed_body['token']}" }
  end
end
