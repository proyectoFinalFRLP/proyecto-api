# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Warehouses API', type: :request do
  let(:company) { Company.create!(name: 'Tenant A', tax_id: '30-11111111-1') }
  let(:user) { User.create!(email: 'a@example.com', password: 'password123', company: company) }
  let(:headers) { auth_headers(user) }

  def auth_headers(user)
    post '/api/v1/auth/login', params: { email: user.email, password: 'password123' }
    { 'Authorization' => "Bearer #{response.parsed_body['token']}" }
  end

  def other_company
    @other_company ||= Company.create!(name: 'Tenant B', tax_id: '30-22222222-2')
  end

  def other_warehouse
    # Current.company_id puede quedar seteado de un request previo y pisaría el
    # company: manual (CompanyScoped#assign_current_company). Forzar nil evita
    # que el fixture nazca en el tenant equivocado.
    @other_warehouse ||= Current.set(company_id: nil) do
      Warehouse.create!(company: other_company, name: 'Otra',
                        zip_code: '2000', address: 'Otra calle')
    end
  end

  def warehouse_attrs
    { name: 'Central', zip_code: '1900', address: 'Calle 1' }
  end

  describe 'GET /api/v1/warehouses' do
    it 'returns 401 without a token' do
      get '/api/v1/warehouses'
      expect(response).to have_http_status(:unauthorized)
    end

    context 'when authenticated' do
      before do
        Current.set(company_id: nil) do
          Warehouse.create!(company: other_company, name: 'Otra', zip_code: '2000', address: 'Otra calle')
        end
        Warehouse.create!(company: company, name: 'Central', zip_code: '1900', address: 'Calle 1')
        Warehouse.create!(company: company, name: 'Satélite', zip_code: '1602', address: 'Calle 2')

        get '/api/v1/warehouses', headers: headers
      end

      it 'returns only the warehouses of the current company', :aggregate_failures do
        body = response.parsed_body
        expect(body.length).to eq(2)
        expect(body.pluck('name')).to match_array(%w[Central Satélite])
      end

      it 'includes warehouse fields' do
        body = response.parsed_body
        expect(body.first.keys).to include('id', 'name', 'zip_code', 'address')
      end
    end
  end

  describe 'GET /api/v1/warehouses/:id' do
    let!(:warehouse) do
      Warehouse.create!(company: company, name: 'Central', zip_code: '1900', address: 'Calle 1')
    end

    it 'returns 401 without a token' do
      get "/api/v1/warehouses/#{warehouse.id}"
      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns the warehouse', :aggregate_failures do
      get "/api/v1/warehouses/#{warehouse.id}", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['name']).to eq('Central')
    end

    it 'returns 404 for a warehouse from another company' do
      get "/api/v1/warehouses/#{other_warehouse.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'POST /api/v1/warehouses' do
    it 'returns 401 without a token' do
      post '/api/v1/warehouses', params: { warehouse: warehouse_attrs }, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it 'creates a warehouse and returns 201', :aggregate_failures do
      expect do
        post '/api/v1/warehouses', params: { warehouse: warehouse_attrs },
                                   headers: headers, as: :json
      end.to change(Warehouse, :count).by(1)

      expect(response).to have_http_status(:created)
    end

    it 'assigns the company from the JWT, ignoring any company_id in the body' do
      post '/api/v1/warehouses',
           params: { warehouse: warehouse_attrs.merge(company_id: other_company.id) },
           headers: headers, as: :json

      expect(Warehouse.last.company).to eq(company)
    end

    it 'returns 422 when required fields are missing' do
      post '/api/v1/warehouses', params: { warehouse: { name: '' } },
                                 headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe 'PUT /api/v1/warehouses/:id' do
    let!(:warehouse) do
      Warehouse.create!(company: company, name: 'Central', zip_code: '1900', address: 'Calle 1')
    end

    it 'returns 401 without a token' do
      put "/api/v1/warehouses/#{warehouse.id}", params: { warehouse: { name: 'Actualizado' } },
                                                as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it 'updates the warehouse', :aggregate_failures do
      put "/api/v1/warehouses/#{warehouse.id}",
          params: { warehouse: { name: 'Actualizado' } },
          headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(warehouse.reload.name).to eq('Actualizado')
    end

    it 'returns 404 for a warehouse from another company' do
      put "/api/v1/warehouses/#{other_warehouse.id}",
          params: { warehouse: { name: 'Hack' } },
          headers: headers, as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'DELETE /api/v1/warehouses/:id' do
    let!(:warehouse) do
      Warehouse.create!(company: company, name: 'Central', zip_code: '1900', address: 'Calle 1')
    end

    it 'returns 401 without a token' do
      delete "/api/v1/warehouses/#{warehouse.id}"
      expect(response).to have_http_status(:unauthorized)
    end

    it 'deletes the warehouse and returns 204', :aggregate_failures do
      expect do
        delete "/api/v1/warehouses/#{warehouse.id}", headers: headers
      end.to change(Warehouse, :count).by(-1)

      expect(response).to have_http_status(:no_content)
    end

    it 'returns 404 for a warehouse from another company' do
      delete "/api/v1/warehouses/#{other_warehouse.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it 'returns 403 when the policy denies access' do
      # Permite probar el rescue de Pundit::NotAuthorizedError: con CompanyScoped
      # el 404 por tenant suele ganarle al authorize, así que se fuerza la negación.
      allow_any_instance_of(WarehousePolicy).to receive(:destroy?).and_return(false) # rubocop:disable RSpec/AnyInstance

      delete "/api/v1/warehouses/#{warehouse.id}", headers: headers

      expect(response).to have_http_status(:forbidden)
    end

    it 'returns 409 and keeps the stock when the warehouse has stock', :aggregate_failures do
      create_warehouse_with_stock

      delete "/api/v1/warehouses/#{warehouse.id}", headers: headers

      expect(response).to have_http_status(:conflict)
      expect(Stock.count).to eq(1)
      expect(Warehouse.find_by(id: warehouse.id)).to be_present
    end
  end

  def create_warehouse_with_stock
    product = Product.create!(company: company, sku: 'SKU-1', name: 'Producto')
    Stock.create!(product: product, warehouse: warehouse, quantity: 10)
  end
end
