require 'rails_helper'

RSpec.describe 'Auth API', type: :request do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-11111111-1', slug: 'acme') }

  # Método y no `let` a propósito: los memoized helpers de este archivo ya están
  # al límite que tolera RSpec/MultipleMemoizedHelpers.
  def tenant_header(slug = company.slug)
    { 'X-Tenant-Slug' => slug }
  end

  def inactive_company
    Company.create!(name: 'Vieja', tax_id: '20-33333333-3', slug: 'vieja', is_active: false)
  end

  describe 'POST /api/v1/auth/register' do
    let(:valid_params) { { email: 'new@test.com', password: 'password123' } }

    def register(params = valid_params, slug: company.slug)
      post '/api/v1/auth/register', params: params, headers: tenant_header(slug)
      [response.status, response.body]
    end

    it 'creates a user', :aggregate_failures do
      expect { register }.to change(User, :count).by(1)
      expect(response).to have_http_status(:created)
    end

    it 'creates the user inside the tenant of the slug' do
      register

      expect(User.last.company).to eq(company)
    end

    it 'returns the user without exposing the password', :aggregate_failures do
      register
      body = response.parsed_body

      expect(body['email']).to eq('new@test.com')
      expect(body.keys).not_to include('password', 'encrypted_password')
    end

    it 'stores the password hashed, never in plain text', :aggregate_failures do
      register

      expect(User.last.encrypted_password).to be_present
      expect(User.last.encrypted_password).not_to eq('password123')
    end

    it 'rejects a duplicate email' do
      User.create!(email: 'dup@test.com', password: 'password123', company: company)
      register(valid_params.merge(email: 'dup@test.com'))

      expect(response).to have_http_status(:unprocessable_content)
    end

    # El agujero que cierra TESIS-120: hasta acá `company_id` era un parámetro
    # permitido y viajaba tal cual a User.create!, así que el body decidía en qué
    # tenant se daba de alta el usuario.
    context 'when the body carries a company_id of another tenant' do
      let(:otra) { Company.create!(name: 'Otra', tax_id: '20-22222222-2', slug: 'otra') }

      it 'ignores it and uses the tenant of the slug', :aggregate_failures do
        register(valid_params.merge(company_id: otra.id))

        expect(response).to have_http_status(:created)
        expect(User.last.company).to eq(company)
        expect(otra.users).to be_empty
      end
    end

    context 'when the tenant cannot be resolved' do
      it 'returns 422 without a slug header', :aggregate_failures do
        expect { post '/api/v1/auth/register', params: valid_params }.not_to change(User, :count)
        expect(response).to have_http_status(:unprocessable_content)
      end

      it 'returns 422 for an unknown slug' do
        register(valid_params, slug: 'no-existe')

        expect(response).to have_http_status(:unprocessable_content)
      end

      it 'returns 422 for an inactive company' do
        register(valid_params, slug: inactive_company.slug)

        expect(response).to have_http_status(:unprocessable_content)
      end

      # Un slug inexistente y uno inactivo tienen que ser indistinguibles: si el
      # cuerpo cambiara, el endpoint diría cuáles tenants existen.
      it 'answers identically for an unknown and an inactive tenant' do
        inactivo = register(valid_params, slug: inactive_company.slug)

        expect(register(valid_params, slug: 'no-existe')).to eq(inactivo)
      end
    end
  end

  describe 'POST /api/v1/auth/login' do
    before { User.create!(email: 'log@test.com', password: 'password123', company: company) }

    def login(email: 'log@test.com', password: 'password123', slug: company.slug)
      post '/api/v1/auth/login', params: { email: email, password: password }, headers: tenant_header(slug)
      [response.status, response.body]
    end

    it 'returns a JWT with user_id and company_id', :aggregate_failures do
      login
      payload = decode_jwt(response.parsed_body['token'])

      expect(payload['user_id']).to eq(User.last.id)
      expect(payload['company_id']).to eq(company.id)
    end

    it 'returns 401 on wrong password' do
      expect(login(password: 'wrong').first).to eq(401)
    end

    it 'returns 401 on unknown email' do
      expect(login(email: 'ghost@test.com').first).to eq(401)
    end

    it 'returns 401 without a slug header' do
      post '/api/v1/auth/login', params: { email: 'log@test.com', password: 'password123' }

      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns 401 for an unknown slug' do
      expect(login(slug: 'no-existe').first).to eq(401)
    end

    it 'returns 401 for an inactive company' do
      inactiva = inactive_company
      User.create!(email: 'baja@test.com', password: 'password123', company: inactiva)

      expect(login(email: 'baja@test.com', slug: inactiva.slug).first).to eq(401)
    end

    # El criterio central de la épica: la credencial de Norte en el portal de Sur
    # tiene que ser indistinguible de una password mal tipeada. Si las dos
    # respuestas difieren, el login de Sur confirma qué emails existen en Norte.
    describe 'cross-tenant login' do
      let(:sur) { Company.create!(name: 'Comercial Sur', tax_id: '20-99999999-9', slug: 'sur') }

      def cross_tenant = login(slug: sur.slug)

      it 'refuses a user of another tenant' do
        expect(cross_tenant.first).to eq(401)
      end

      it 'issues no token to a user of another tenant' do
        cross_tenant

        expect(response.parsed_body).not_to have_key('token')
      end

      it 'responds byte for byte like a wrong password' do
        expect(cross_tenant).to eq(login(password: 'wrong'))
      end

      it 'responds byte for byte like an unknown email' do
        expect(cross_tenant).to eq(login(email: 'ghost@test.com'))
      end

      it 'responds byte for byte like an unknown tenant' do
        expect(cross_tenant).to eq(login(slug: 'no-existe'))
      end
    end
  end

  describe 'DELETE /api/v1/auth/logout' do
    let(:user) { User.create!(email: 'out@test.com', password: 'password123', company: company) }
    let(:token) do
      post '/api/v1/auth/login', params: { email: user.email, password: 'password123' }, headers: tenant_header
      response.parsed_body['token']
    end
    let(:auth) { { 'Authorization' => "Bearer #{token}" } }

    it 'returns 204' do
      delete '/api/v1/auth/logout', headers: auth
      expect(response).to have_http_status(:no_content)
    end

    it 'revokes the token: reusing it no longer authenticates', :aggregate_failures do
      get '/api/v1/warehouses', headers: auth
      expect(response).to have_http_status(:ok)

      delete '/api/v1/auth/logout', headers: auth

      get '/api/v1/warehouses', headers: auth
      expect(response).to have_http_status(:unauthorized)
    end

    it 'records the revoked token in the denylist' do
      expect { delete '/api/v1/auth/logout', headers: auth }.to change(JwtDenylist, :count).by(1)
    end

    # El cliente puede reintentar por una respuesta perdida; el segundo intento
    # llega ya con el token revocado y debe fallar como cualquier otro request,
    # no romper por el jti repetido.
    it 'is safe to call twice' do
      delete '/api/v1/auth/logout', headers: auth
      delete '/api/v1/auth/logout', headers: auth
      expect(response).to have_http_status(:unauthorized)
    end

    it 'requires authentication' do
      delete '/api/v1/auth/logout'
      expect(response).to have_http_status(:unauthorized)
    end

    # Revocar es por token, no por usuario: una sesión abierta en otro navegador
    # no tiene por qué cerrarse porque alguien salió en este.
    context 'with the same user logged in from two places' do
      let(:otra_sesion) do
        post '/api/v1/auth/login', params: { email: user.email, password: 'password123' }, headers: tenant_header
        { 'Authorization' => "Bearer #{response.parsed_body['token']}" }
      end

      before do
        primera = auth
        otra_sesion
        delete '/api/v1/auth/logout', headers: primera
      end

      it 'revokes the session that logged out' do
        get '/api/v1/warehouses', headers: auth
        expect(response).to have_http_status(:unauthorized)
      end

      it 'leaves the other session alive' do
        get '/api/v1/warehouses', headers: otra_sesion
        expect(response).to have_http_status(:ok)
      end
    end
  end
end
