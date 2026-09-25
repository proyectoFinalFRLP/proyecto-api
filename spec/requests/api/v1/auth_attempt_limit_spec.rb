# frozen_string_literal: true

require 'rails_helper'

# Límite de intentos de login y registro. Lo pidió la QA de TESIS-82: después
# de 30 passwords incorrectas seguidas, la correcta entraba igual.
#
# En test la cache es :null_store y el límite nunca se alcanza, así los specs
# que loguean muchas veces no chocan con él. Acá el contador usa una cache de
# verdad, sólo durante cada ejemplo.
RSpec.describe 'Auth attempt limit', type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:company) { Company.create!(name: 'Acme', tax_id: '20-11111111-1', slug: 'acme') }
  let(:counter) { ActiveSupport::Cache::MemoryStore.new }
  let(:max_attempts) { Api::V1::Auth::AttemptLimit::MAX_ATTEMPTS }

  before do
    User.create!(email: 'log@test.com', password: 'password123', company: company)
    store = Api::V1::Auth::SessionsController.cache_store
    allow(store).to receive(:increment) { |*args, **options| counter.increment(*args, **options) }
    allow(store).to receive(:read) { |*args, **options| counter.read(*args, **options) }
  end

  def login(password: 'wrong', ip: '203.0.113.7')
    post '/api/v1/auth/login', params: { email: 'log@test.com', password: password },
                               headers: { 'X-Tenant-Slug' => company.slug, 'REMOTE_ADDR' => ip }
    response
  end

  def use_up_attempts(ip: '203.0.113.7')
    max_attempts.times { login(ip: ip) }
  end

  it 'lets every attempt of the window through' do
    (max_attempts - 1).times { login }

    expect(login(password: 'password123')).to have_http_status(:ok)
  end

  # Lo que se frena es al que prueba contraseñas, no al que entra: un depósito
  # con varios operarios detrás del mismo NAT loguea muchas veces al empezar el
  # turno.
  it 'does not count the logins that succeed' do
    (max_attempts + 2).times { login(password: 'password123') }

    expect(response).to have_http_status(:ok)
  end

  it 'answers 429 once the attempts run out, even with the right password', :aggregate_failures do
    use_up_attempts
    login(password: 'password123')

    expect(response).to have_http_status(:too_many_requests)
    expect(response.parsed_body['error']).to eq('Too many attempts, try again later')
  end

  it 'tells the client when it can try again' do
    use_up_attempts

    expect(login.headers['Retry-After']).to eq('180')
  end

  it 'counts each IP on its own' do
    use_up_attempts(ip: '203.0.113.7')

    expect(login(password: 'password123', ip: '198.51.100.9')).to have_http_status(:ok)
  end

  it 'lets the IP in again once the window is over' do
    use_up_attempts

    travel(Api::V1::Auth::AttemptLimit::WINDOW + 1.second) do
      expect(login(password: 'password123')).to have_http_status(:ok)
    end
  end

  it 'limits the registration too' do
    (max_attempts + 1).times do |n|
      post '/api/v1/auth/register', params: { email: "nuevo#{n}@test.com", password: 'password123' },
                                    headers: { 'X-Tenant-Slug' => company.slug }
    end

    expect(response).to have_http_status(:too_many_requests)
  end

  # El logout no es un intento de adivinar nada: no cuenta ni se frena.
  it 'does not limit the logout' do
    token = login(password: 'password123').parsed_body['token']
    use_up_attempts

    delete '/api/v1/auth/logout', headers: { 'Authorization' => "Bearer #{token}", 'REMOTE_ADDR' => '203.0.113.7' }

    expect(response).to have_http_status(:no_content)
  end
end
