# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Warehouses API', type: :request do
  let(:company) { Company.create!(name: 'Tenant A', tax_id: '30-11111111-1') }
  let(:user) { User.create!(email: 'a@example.com', password: 'password123', company: company) }
  let(:headers) { auth_headers(user) }

  def auth_headers(user)
    post '/api/v1/auth/login', params: { email: user.email, password: 'password123' }, headers: { 'X-Tenant-Slug' => user.company.slug }
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

  # Unidades guardadas en cada deposito (TESIS-127). Alimentan el widget de
  # capacidad del panel, que compara depositos entre si: el modelo no tiene
  # capacidad maxima contra la cual medir una ocupacion.
  describe 'GET /api/v1/warehouses, stored units' do
    def stock_for(warehouse, quantity)
      product = Product.create!(company: company, sku: "SKU-#{quantity}", name: "Producto #{quantity}")
      Stock.create!(product: product, warehouse: warehouse, quantity: quantity)
    end

    def listed
      get '/api/v1/warehouses', headers: headers
      response.parsed_body['data'].to_h { |row| [row['name'], row['stored_units']] }
    end

    it 'adds up every stock row of the warehouse' do
      central = Warehouse.create!(company: company, name: 'Central', zip_code: '1900', address: 'Calle 1')
      stock_for(central, 30)
      stock_for(central, 12)

      expect(listed['Central']).to eq(42)
    end

    # Cero es un dato: el deposito existe y esta vacio. Un null obligaria a la
    # pantalla a distinguir "vacio" de "no lo se", y no hay tal distincion.
    it 'answers zero for a warehouse with no stock at all' do
      Warehouse.create!(company: company, name: 'Vacio', zip_code: '1901', address: 'Calle 2')

      expect(listed['Vacio']).to eq(0)
    end

    it 'counts each warehouse on its own' do
      central = Warehouse.create!(company: company, name: 'Central', zip_code: '1900', address: 'Calle 1')
      satelite = Warehouse.create!(company: company, name: 'Satelite', zip_code: '1602', address: 'Calle 3')
      stock_for(central, 30)
      stock_for(satelite, 7)

      expect(listed).to eq('Central' => 30, 'Satelite' => 7)
    end

    def three_stocked_warehouses
      3.times do |i|
        warehouse = Warehouse.create!(company: company, name: "CD #{i}", zip_code: '1900',
                                      address: "Calle #{i}")
        stock_for(warehouse, i + 1)
      end
    end

    # Cuantas veces se consulto la tabla `stocks` para responder el listado.
    def stock_queries_while(&)
      consultas = 0
      contar = lambda { |_name, _start, _finish, _id, payload|
        consultas += 1 if payload[:sql].include?('FROM "stocks"')
      }
      ActiveSupport::Notifications.subscribed(contar, 'sql.active_record', &)
      consultas
    end

    # El motivo del scope: sin el, el serializer sumaria por asociacion y haria
    # una consulta por deposito. Con el, hay a lo sumo una, sin importar cuantos
    # depositos haya.
    it 'aggregates in a single query instead of one per warehouse' do
      three_stocked_warehouses

      consultas = stock_queries_while { get '/api/v1/warehouses', headers: headers }

      expect(consultas).to be <= 1
    end

    # El detalle no pasa por el scope: ahi `stored_units` cae a sumar por
    # asociacion, y tiene que dar lo mismo.
    it 'answers the same number on the detail, which does not use the scope' do
      central = Warehouse.create!(company: company, name: 'Central', zip_code: '1900', address: 'Calle 1')
      stock_for(central, 30)

      get "/api/v1/warehouses/#{central.id}", headers: headers

      expect(response.parsed_body['stored_units']).to eq(30)
    end

    it 'never counts the stock of another company' do
      Warehouse.create!(company: company, name: 'Central', zip_code: '1900', address: 'Calle 1')
      other_warehouse

      expect(listed.keys).to eq(['Central'])
    end
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
        expect(body['data'].length).to eq(2)
        expect(body['data'].pluck('name')).to match_array(%w[Central Satélite])
      end

      it 'includes warehouse fields inside the data envelope' do
        body = response.parsed_body['data']
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

    it 'returns 400 when the warehouse key is missing' do
      post '/api/v1/warehouses', params: {}, headers: headers, as: :json
      expect(response).to have_http_status(:bad_request)
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

    it 'updates via PATCH as well', :aggregate_failures do
      patch "/api/v1/warehouses/#{warehouse.id}",
            params: { warehouse: { name: 'Actualizado' } },
            headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(warehouse.reload.name).to eq('Actualizado')
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

    it 'says the stock is what blocks it' do
      create_warehouse_with_stock

      delete "/api/v1/warehouses/#{warehouse.id}", headers: headers

      expect(response.parsed_body['error']).to eq('Cannot delete warehouse with existing stock')
    end

    # TESIS-126: la línea recuerda su depósito para devolverle unidades al
    # modificar la orden. Borrarlo dejaría esa devolución sin destino.
    context 'when order lines were taken from it and it has no stock left' do
      before { create_order_line_from_warehouse }

      it 'returns 409 and keeps the warehouse', :aggregate_failures do
        delete "/api/v1/warehouses/#{warehouse.id}", headers: headers

        expect(response).to have_http_status(:conflict)
        expect(Warehouse.find_by(id: warehouse.id)).to be_present
      end

      it 'says the order lines are what block it' do
        delete "/api/v1/warehouses/#{warehouse.id}", headers: headers

        expect(response.parsed_body['error'])
          .to eq('Cannot delete warehouse with order lines taken from it')
      end
    end
  end

  def create_warehouse_with_stock
    product = Product.create!(company: company, sku: 'SKU-1', name: 'Producto')
    Stock.create!(product: product, warehouse: warehouse, quantity: 10)
  end

  def create_order_line_from_warehouse
    product = Product.create!(company: company, sku: 'SKU-2', name: 'Vendido')
    order = Order.create!(company: company, customer_name: 'Cliente')
    OrderItem.create!(order: order, product: product, warehouse: warehouse,
                      quantity: 1, unit_price: 100)
  end
end
