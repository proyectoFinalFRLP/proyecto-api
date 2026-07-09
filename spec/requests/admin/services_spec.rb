# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Admin services panel', type: :request do
  let(:auth_headers) do
    credentials = ActionController::HttpAuthentication::Basic.encode_credentials('admin', 'admin')
    { 'HTTP_AUTHORIZATION' => credentials }
  end
  let!(:service) do
    Service.create!(service_name: 'Mercado Libre', type: 'ecommerce',
                    uri: 'https://api.mercadolibre.com', http_method: 'GET')
  end

  describe 'authentication' do
    it 'rejects requests without credentials' do
      get '/admin/services'
      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects requests with wrong credentials' do
      wrong = ActionController::HttpAuthentication::Basic.encode_credentials('admin', 'nope')
      get '/admin/services', headers: { 'HTTP_AUTHORIZATION' => wrong }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'GET /admin/services' do
    it 'lists the services with their key columns', :aggregate_failures do
      get '/admin/services', headers: auth_headers
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Mercado Libre', 'ecommerce', 'https://api.mercadolibre.com')
    end
  end

  describe 'POST /admin/services' do
    it 'creates a service with valid JSON mappers' do
      expect { post '/admin/services', params: valid_params, headers: auth_headers }
        .to change(Service, :count).by(1)
    end

    it 'persists the mappers as parsed JSON objects' do
      post '/admin/services', params: valid_params, headers: auth_headers
      expect(Service.last.request_mapper).to eq('customer_zip_code' => 'destino.codigoPostal')
    end

    it 'redirects to the created service' do
      post '/admin/services', params: valid_params, headers: auth_headers
      expect(response).to redirect_to(admin_service_path(Service.last))
    end

    it 'rejects an invalid JSON mapper without persisting', :aggregate_failures do
      expect { post '/admin/services', params: invalid_json_params, headers: auth_headers }
        .not_to change(Service, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('no es un JSON válido')
    end

    it 'rejects a JSON mapper that is not an object', :aggregate_failures do
      expect { post '/admin/services', params: scalar_json_params, headers: auth_headers }
        .not_to change(Service, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe 'PATCH /admin/services/:id' do
    it 'updates the service attributes' do
      patch "/admin/services/#{service.id}",
            params: { service: { uri: 'https://nueva.uri.com' } }, headers: auth_headers
      expect(service.reload.uri).to eq('https://nueva.uri.com')
    end

    it 'keeps the stored mappers when the field is submitted empty' do
      service.update!(request_mapper: { 'a' => 'b' })
      patch "/admin/services/#{service.id}",
            params: { service: { request_mapper: '' } }, headers: auth_headers
      expect(service.reload.request_mapper).to eq('a' => 'b')
    end
  end

  def valid_params
    { service: { service_name: 'Andreani', type: 'courier', uri: 'https://api.andreani.com',
                 http_method: 'POST',
                 request_mapper: '{"customer_zip_code": "destino.codigoPostal"}' } }
  end

  def invalid_json_params
    valid_params.deep_merge(service: { request_mapper: '{esto no es json' })
  end

  def scalar_json_params
    valid_params.deep_merge(service: { request_mapper: '"solo-un-string"' })
  end
end
