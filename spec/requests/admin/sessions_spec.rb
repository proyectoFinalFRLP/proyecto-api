# frozen_string_literal: true

require 'rails_helper'

# El ciclo de sesión del backoffice (TESIS-93).
#
# `spec/requests/admin/services_spec.rb` cubre el ingreso; la salida no la
# probaba nadie, y es la mitad que decide qué ve el administrador después de
# cerrar sesión: sin el `after_sign_out_path_for` de este controller, Devise
# manda a la raíz, que en una app API-only es un 404.
RSpec.describe 'Admin sessions', type: :request do
  let(:admin_user) { AdminUser.create!(email: 'admin@backoffice.com', password: 'admin123') }

  def sign_in_through_the_form
    post '/admin/sign_in',
         params: { admin_user: { email: admin_user.email, password: 'admin123' } }
  end

  describe 'signing out' do
    before { sign_in_through_the_form }

    it 'sends the administrator back to the login page' do
      delete '/admin/sign_out'

      expect(response).to redirect_to('/admin/sign_in')
    end

    it 'closes the session: the panel is no longer reachable' do
      delete '/admin/sign_out'
      get '/admin/resources/services'

      expect(response).to redirect_to('/admin/sign_in')
    end
  end

  describe 'signing in' do
    it 'lands on the panel and not on the root of the API' do
      sign_in_through_the_form

      expect(response).to redirect_to('/admin')
    end
  end
end
