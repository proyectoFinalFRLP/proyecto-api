# frozen_string_literal: true

require 'rails_helper'

# Límite de intentos del login del backoffice. Lo pidió la QA de TESIS-129:
# después de 30 passwords incorrectas seguidas, la correcta entraba igual.
#
# En test la cache es :null_store y el límite nunca se alcanza, así los specs
# que loguean muchas veces no chocan con él. Acá el contador usa una cache de
# verdad, sólo durante cada ejemplo.
RSpec.describe 'Admin login attempt limit', type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:admin_user) { AdminUser.create!(email: 'admin@backoffice.com', password: 'admin123') }
  let(:counter) { ActiveSupport::Cache::MemoryStore.new }
  let(:max_attempts) { FailedAttemptLimit::MAX_ATTEMPTS }

  before do
    store = Admin::SessionsController.cache_store
    allow(store).to receive(:increment) { |*args, **options| counter.increment(*args, **options) }
    allow(store).to receive(:read) { |*args, **options| counter.read(*args, **options) }
  end

  def log_in(password: 'wrong', ip: '203.0.113.7')
    post '/admin/sign_in', params: { admin_user: { email: admin_user.email, password: } },
                           headers: { 'REMOTE_ADDR' => ip }
    response
  end

  def use_up_attempts(ip: '203.0.113.7')
    max_attempts.times { log_in(ip:) }
  end

  # Uno más que el máximo, así la última respuesta ya es la del límite.
  def use_up_api_attempts(ip: '203.0.113.7')
    (max_attempts + 1).times do
      post '/api/v1/auth/login', params: { email: 'nadie@test.com', password: 'wrong' },
                                 headers: { 'REMOTE_ADDR' => ip }
    end
    response
  end

  it 'lets every attempt of the window through' do
    (max_attempts - 1).times { log_in }

    expect(log_in(password: 'admin123')).to redirect_to('/admin')
  end

  # Sin el reset!, el segundo login encontraría la sesión abierta y Devise
  # redirigiría a /admin sin evaluar nada.
  it 'does not count the logins that succeed' do
    (max_attempts + 2).times do
      reset!
      log_in(password: 'admin123')
    end

    expect(response).to redirect_to('/admin')
  end

  it 'answers 429 once the attempts run out, even with the right password', :aggregate_failures do
    use_up_attempts
    log_in(password: 'admin123')

    expect(response).to have_http_status(:too_many_requests)
    expect(response.body).to include('Too many failed attempts, try again later.')
  end

  it 'does not open a session with the right password once the attempts run out' do
    use_up_attempts
    log_in(password: 'admin123')
    get '/admin/resources/services'

    expect(response).to redirect_to('/admin/sign_in')
  end

  it 'tells the client when it can try again' do
    use_up_attempts

    expect(log_in.headers['Retry-After']).to eq('180')
  end

  it 'counts each IP on its own' do
    use_up_attempts(ip: '203.0.113.7')

    expect(log_in(password: 'admin123', ip: '198.51.100.9')).to redirect_to('/admin')
  end

  # El contador es el mismo que el del login de la API, pero la cuenta no:
  # agotar los intentos de uno no bloquea el otro desde la misma IP.
  it 'keeps a count apart from the API login', :aggregate_failures do
    expect(use_up_api_attempts).to have_http_status(:too_many_requests)
    expect(log_in(password: 'admin123')).to redirect_to('/admin')
  end

  it 'lets the attempts through again once the window is over' do
    use_up_attempts
    travel(FailedAttemptLimit::WINDOW + 1.second)

    expect(log_in(password: 'admin123')).to redirect_to('/admin')
  end
end
