# frozen_string_literal: true

require 'rails_helper'

# El backoffice (navegacional, con sesión) y la API (stateless, JWT) comparten
# Devise: sin autenticar, cada uno debe fallar a su manera.
RSpec.describe 'Unauthenticated handling', type: :request do
  describe 'API requests' do
    it 'returns 401 instead of redirecting to a login page' do
      get '/api/v1/integrations'
      expect(response).to have_http_status(:unauthorized)
    end

    it 'responds with a JSON error body', :aggregate_failures do
      get '/api/v1/integrations'
      expect(response.media_type).to eq('application/json')
      expect(response.parsed_body).to have_key('error')
    end

    it 'does not send a redirect location' do
      get '/api/v1/integrations'
      expect(response.location).to be_nil
    end
  end

  describe 'backoffice requests' do
    it 'redirects to the admin login page' do
      get '/admin/resources/services'
      expect(response).to redirect_to('/admin/sign_in')
    end
  end
end
