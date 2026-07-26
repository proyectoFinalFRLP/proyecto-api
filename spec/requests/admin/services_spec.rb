# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Admin services panel (Avo)', type: :request do
  let(:admin_user) { AdminUser.create!(email: 'admin@backoffice.com', password: 'admin123') }
  let!(:service) do
    Service.create!(service_name: 'Mercado Libre', type: 'ecommerce',
                    uri: 'https://api.mercadolibre.com', http_method: 'GET')
  end

  describe 'authentication' do
    it 'redirects to the login page without a session' do
      get '/admin/resources/services'
      expect(response).to redirect_to('/admin/sign_in')
    end

    it 'rejects a login with wrong credentials', :aggregate_failures do
      post '/admin/sign_in', params: { admin_user: { email: admin_user.email, password: 'nope' } }
      get '/admin/resources/services'
      expect(response).to redirect_to('/admin/sign_in')
    end

    it 'grants access after logging in through the form' do
      post '/admin/sign_in',
           params: { admin_user: { email: admin_user.email, password: 'admin123' } }
      get '/admin/resources/services'
      expect(response).to have_http_status(:ok)
    end
  end

  context 'when signed in as admin' do
    before { sign_in admin_user }

    describe 'GET /admin/resources/services' do
      it 'lists the services', :aggregate_failures do
        get '/admin/resources/services'
        expect(response).to have_http_status(:ok)
        expect(response.body).to include('Mercado Libre')
      end
    end

    describe 'POST /admin/resources/services' do
      it 'creates a service with valid JSON mappers' do
        expect { post '/admin/resources/services', params: valid_params }
          .to change(Service, :count).by(1)
      end

      it 'persists the mappers as parsed JSON objects' do
        post '/admin/resources/services', params: valid_params
        expect(Service.last.request_mapper).to eq('customer_zip_code' => 'destino.codigoPostal')
      end

      it 'rejects an invalid JSON mapper without persisting', :aggregate_failures do
        expect { post '/admin/resources/services', params: invalid_json_params }
          .not_to change(Service, :count)
        expect(response.body).to include('no es un JSON válido')
      end

      it 'rejects a JSON mapper that is not an object' do
        expect { post '/admin/resources/services', params: scalar_json_params }
          .not_to change(Service, :count)
      end
    end

    describe 'PATCH /admin/resources/services/:id' do
      it 'updates the service attributes' do
        patch "/admin/resources/services/#{service.id}",
              params: { service: { uri: 'https://nueva.uri.com' } }
        expect(service.reload.uri).to eq('https://nueva.uri.com')
      end
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
