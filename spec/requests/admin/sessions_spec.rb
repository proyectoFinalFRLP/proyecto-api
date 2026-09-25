# frozen_string_literal: true

require 'rails_helper'

# Login y sesión del backoffice (QA de TESIS-129). El administrador ve los
# datos de todas las empresas, así que una sesión que dura de más o que
# sobrevive al logout las expone a todas a la vez.
RSpec.describe 'Admin backoffice session', type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:admin_user) { AdminUser.create!(email: 'admin@backoffice.com', password: 'admin123') }
  let(:panel_path) { '/admin/resources/services' }
  let(:session_cookie) { '_proyecto_api_session' }

  def log_in(email: admin_user.email, password: 'admin123', remember: '0')
    post '/admin/sign_in', params: { admin_user: { email:, password:, remember_me: remember } }
  end

  # Sigue las redirecciones como el navegador y dice en qué página termina. El
  # tope evita que un loop de redirecciones cuelgue la suite: hubo uno cuando
  # el vencimiento de la sesión no llegaba a la cookie (ver config/application.rb).
  def landing_path(path, max_redirects: 5)
    get path
    max_redirects.times { follow_redirect! if response.redirect? }
    request.path
  end

  # El status y el mensaje de alerta con que responde un intento de login.
  def login_answer(**credentials)
    log_in(**credentials)
    [response.status, response.body[/class="alert">([^<]*)/, 1]]
  end

  # Cuántas veces corrió bcrypt durante un intento de login.
  def bcrypt_runs_for(**credentials)
    runs = 0
    allow(BCrypt::Engine).to receive(:hash_secret).and_wrap_original do |original, *args|
      runs += 1
      original.call(*args)
    end
    log_in(**credentials)
    runs
  end

  describe 'failed login' do
    let(:generic_answer) { [422, 'Invalid email or password.'] }

    it 'answers a wrong password and an unknown email the same way', :aggregate_failures do
      expect(login_answer(password: 'wrong')).to eq(generic_answer)
      expect(login_answer(email: 'nadie@backoffice.com', password: 'wrong')).to eq(generic_answer)
    end

    # Sin config.paranoid el login de un email inexistente volvía ~200 ms antes,
    # porque bcrypt sólo corría cuando había cuenta: el tiempo decía qué emails
    # existen aunque el mensaje fuera el mismo.
    it 'runs bcrypt as many times for an unknown email as for a wrong password' do
      admin_user
      wrong_password = bcrypt_runs_for(password: 'wrong')

      expect(bcrypt_runs_for(email: 'nadie@backoffice.com', password: 'wrong')).to eq(wrong_password)
    end
  end

  describe 'session cookie' do
    it 'is not readable from JavaScript nor sent by cross-site requests', :aggregate_failures do
      log_in
      cookie = Array(response.headers['set-cookie']).flat_map(&:lines)
                                                    .find { |line| line.start_with?(session_cookie) }

      expect(cookie).to match(/;\s*httponly/i)
      expect(cookie).to match(/;\s*samesite=lax/i)
    end
  end

  describe 'logout' do
    before { log_in }

    it 'sends the browser that logged out back to the login' do
      delete '/admin/sign_out'

      expect(landing_path(panel_path)).to eq('/admin/sign_in')
    end

    # El cookie store no guarda nada del lado del servidor: sin rotar el token
    # de la cuenta, esta copia seguía abriendo el panel después del logout.
    it 'does not accept a copy of the session cookie taken before logging out' do
      stolen = cookies[session_cookie]
      delete '/admin/sign_out'
      cookies[session_cookie] = stolen

      expect(landing_path(panel_path)).to eq('/admin/sign_in')
    end

    # Sin no-store, el botón «atrás» del navegador podía volver a mostrar una
    # página del panel desde su cache después del logout.
    it 'keeps the panel pages out of the browser cache' do
      get panel_path

      expect(response.headers['Cache-Control']).to eq('no-store')
    end
  end

  describe 'inactivity timeout' do
    it 'ends the session after 30 minutes without activity' do
      log_in
      travel 31.minutes

      expect(landing_path(panel_path)).to eq('/admin/sign_in')
    end

    it 'counts the 30 minutes from the last request, not from the login' do
      log_in
      travel 20.minutes
      get panel_path
      travel 20.minutes

      expect(landing_path(panel_path)).to eq(panel_path)
    end

    # Aceptado en ADR-017: «Recordarme» estira la sesión a las 2 semanas de
    # :rememberable, y Devise no aplica el timeout mientras esa cookie vale.
    it 'does not apply to a session opened with Recordarme' do
      log_in(remember: '1')
      travel 31.minutes

      expect(landing_path(panel_path)).to eq(panel_path)
    end
  end

  # En test la protección CSRF está apagada (config/environments/test.rb): acá
  # se prende para verificar que los formularios la exigen.
  describe 'CSRF protection' do
    around do |example|
      ActionController::Base.allow_forgery_protection = true
      example.run
    ensure
      ActionController::Base.allow_forgery_protection = false
    end

    it 'accepts the login with the token of the form' do
      get '/admin/sign_in'
      token = response.body[/name="authenticity_token" value="([^"]+)"/, 1]
      post '/admin/sign_in', params: { authenticity_token: token,
                                       admin_user: { email: admin_user.email, password: 'admin123' } }

      expect(response).to redirect_to('/admin')
    end

    it 'rejects a login without the token' do
      log_in

      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'rejects a backoffice form sent without the token', :aggregate_failures do
      sign_in admin_user

      expect { post '/admin/resources/warehouses', params: { warehouse: { name: 'CSRF' } } }
        .not_to change(Warehouse, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end
  end
end
