# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Orders API', type: :request do
  let(:company) do
    Company.create!(name: 'Acme', tax_id: '20-12345678-9')
  end
  let(:user) { User.create!(email: 'a@acme.com', password: 'pass123', company: company) }
  let(:headers) { auth_headers(user) }
  let(:product) { Product.create!(company: company, sku: 'SKU-001', name: 'Celular') }
  let(:warehouse) do
    Warehouse.create!(company: company, name: 'Central',
                      zip_code: '1900', address: 'Av 1')
  end

  def auth_headers(user)
    post '/api/v1/auth/login', params: { email: user.email, password: 'pass123' }
    { 'Authorization' => "Bearer #{response.parsed_body['token']}" }
  end

  before do
    Current.company_id = company.id
    Stock.create!(product: product, warehouse: warehouse, quantity: 20)
  end

  def default_item
    { product_id: product.id, warehouse_id: warehouse.id,
      quantity: 2, unit_price: 150.00 }
  end

  def build_payload(items: nil)
    { order: { customer_name: 'Juan Pérez', customer_document: '12345678',
               items: items || [default_item] } }
  end

  def post_order(payload = build_payload)
    post '/api/v1/orders', params: payload, headers: headers, as: :json
  end

  def create_second_product
    p2 = Product.create!(company: company, sku: 'SKU-002', name: 'Tablet')
    Stock.create!(product: p2, warehouse: warehouse, quantity: 10)
    p2
  end

  def multi_item_payload(prod1, prod2)
    [
      { product_id: prod1.id, warehouse_id: warehouse.id,
        quantity: 3, unit_price: 150.00 },
      { product_id: prod2.id, warehouse_id: warehouse.id,
        quantity: 1, unit_price: 300.00 }
    ]
  end

  def other_company_warehouse
    other_co = Company.create!(name: 'Other', tax_id: '30-99999999-0')
    Current.set(company_id: nil) do
      Warehouse.create!(company: other_co, name: 'Other',
                        zip_code: '2000', address: 'X')
    end
  end

  # ------------------------------------------------------------------ TESIS-112
  # Cuenta las consultas que matchean un patrón mientras corre el bloque. Mismo
  # helper que products_spec: acá fija que el detalle no haga N+1 sobre los
  # productos de las líneas.
  def count_queries(matching:, &block)
    count = 0
    counter = lambda do |_name, _started, _finished, _id, payload|
      count += 1 if payload[:sql].to_s.match?(matching)
    end

    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &block)

    count
  end

  # Crea una orden sin pasar por el endpoint: los ejemplos de lectura no
  # necesitan ejercitar el alta ni descontar stock.
  def make_order(name: 'Juan Pérez', status: 'pending', external_id: nil, items: 1)
    order = Order.create!(company: company, customer_name: name, status: status,
                          external_order_id: external_id)
    items.times do
      OrderItem.create!(order: order, product: product, quantity: 1, unit_price: 100)
    end
    order
  end

  def order_of_another_company
    other_co = Company.create!(name: 'Rival', tax_id: '30-88888888-1')
    Current.set(company_id: other_co.id) do
      Order.create!(company: other_co, customer_name: 'Ajeno', status: 'pending')
    end
  end

  describe 'GET /api/v1/orders' do
    it 'returns 401 without a token' do
      get '/api/v1/orders'

      expect(response).to have_http_status(:unauthorized)
    end

    context 'when authenticated' do
      it 'returns 200' do
        make_order
        get '/api/v1/orders', headers: headers

        expect(response).to have_http_status(:ok)
      end

      it 'returns only the orders of the company in the token' do
        mine = make_order(name: 'Mía')
        order_of_another_company

        get '/api/v1/orders', headers: headers

        expect(response.parsed_body['data'].pluck('id')).to eq([mine.id])
      end

      it 'reports the total in meta' do
        2.times { make_order }

        get '/api/v1/orders', headers: headers

        expect(response.parsed_body['meta']['total']).to eq(2)
      end

      it 'returns the newest order first' do
        make_order(name: 'Vieja')
        newest = make_order(name: 'Nueva')

        get '/api/v1/orders', headers: headers

        expect(response.parsed_body['data'].first['id']).to eq(newest.id)
      end

      it 'counts the items of each row' do
        make_order(items: 3)

        get '/api/v1/orders', headers: headers

        expect(response.parsed_body['data'].first['item_count']).to eq(3)
      end

      it 'does not include the order items in the list' do
        make_order

        get '/api/v1/orders', headers: headers

        expect(response.parsed_body['data'].first).not_to have_key('order_items')
      end

      it 'limits the page to per_page rows' do
        3.times { make_order }

        get '/api/v1/orders', params: { per_page: 2 }, headers: headers

        expect(response.parsed_body['data'].size).to eq(2)
      end

      it 'caps per_page at 100' do
        make_order

        get '/api/v1/orders', params: { per_page: 500 }, headers: headers

        expect(response.parsed_body['meta']['per_page']).to eq(100)
      end
    end

    context 'when filtering by status' do
      before do
        make_order(name: 'Pendiente', status: 'pending')
        make_order(name: 'Cancelada', status: 'cancelled')
      end

      it 'returns only the rows of that status' do
        get '/api/v1/orders', params: { status: 'cancelled' }, headers: headers

        expect(response.parsed_body['data'].pluck('status')).to eq(['cancelled'])
      end

      # De este número salen los KPIs de TESIS-53, que los pide con
      # `?status=pending&per_page=1` y lee sólo el meta: si el total contara la
      # tabla entera en vez del filtro, el KPI mentiría.
      it 'counts only the filtered rows in meta.total' do
        get '/api/v1/orders', params: { status: 'cancelled' }, headers: headers

        expect(response.parsed_body['meta']['total']).to eq(1)
      end

      it 'returns an empty list for an unknown status, without failing' do
        get '/api/v1/orders', params: { status: 'nope' }, headers: headers

        expect(response.parsed_body['data']).to be_empty
      end
    end

    context 'when searching' do
      before do
        make_order(name: 'Ferretería Pérez', external_id: 'ML-1001')
        make_order(name: 'Otra Cosa', external_id: 'TN-2002')
      end

      it 'matches by customer name' do
        get '/api/v1/orders', params: { search: 'ferret' }, headers: headers

        expect(response.parsed_body['data'].pluck('customer_name'))
          .to eq(['Ferretería Pérez'])
      end

      it 'matches by external order id' do
        get '/api/v1/orders', params: { search: 'TN-20' }, headers: headers

        expect(response.parsed_body['data'].pluck('external_order_id'))
          .to eq(['TN-2002'])
      end

      it 'ignores case' do
        get '/api/v1/orders', params: { search: 'FERRET' }, headers: headers

        expect(response.parsed_body['data'].size).to eq(1)
      end

      it 'counts only the matching rows in meta.total' do
        get '/api/v1/orders', params: { search: 'ferret' }, headers: headers

        expect(response.parsed_body['meta']['total']).to eq(1)
      end

      # Un `%` tipeado por el usuario es texto a buscar, no un comodín: sin
      # escaparlo, buscar "%" devolvería la tabla entera.
      it 'treats a literal % as text and not as a wildcard' do
        get '/api/v1/orders', params: { search: '%' }, headers: headers

        expect(response.parsed_body['data']).to be_empty
      end
    end
  end

  describe 'GET /api/v1/orders/:id' do
    it 'returns 401 without a token' do
      get "/api/v1/orders/#{make_order.id}"

      expect(response).to have_http_status(:unauthorized)
    end

    context 'when authenticated' do
      it 'returns 200' do
        get "/api/v1/orders/#{make_order.id}", headers: headers

        expect(response).to have_http_status(:ok)
      end

      it 'returns the order items' do
        get "/api/v1/orders/#{make_order(items: 2).id}", headers: headers

        expect(response.parsed_body['order_items'].size).to eq(2)
      end

      it 'returns the product of each line' do
        get "/api/v1/orders/#{make_order.id}", headers: headers

        expect(response.parsed_body['order_items'].first['product'])
          .to include('id' => product.id, 'sku' => product.sku, 'name' => product.name)
      end

      it 'returns unit_price as a number, not a string' do
        get "/api/v1/orders/#{make_order.id}", headers: headers

        expect(response.parsed_body['order_items'].first['unit_price']).to be_a(Numeric)
      end

      # Fija la precarga: con tres líneas del mismo producto tiene que haber UN
      # solo SELECT sobre products. Sin `includes(order_items: :product)` serían
      # tres, y con diez líneas, diez.
      it 'loads the products of the lines in a single query' do
        order = make_order(items: 3)

        queries = count_queries(matching: /FROM "products"/) do
          get "/api/v1/orders/#{order.id}", headers: headers
        end

        expect(queries).to eq(1)
      end

      # 404 y no 403: un 403 confirmaría que esa orden existe.
      it 'returns 404 for an order of another company' do
        get "/api/v1/orders/#{order_of_another_company.id}", headers: headers

        expect(response).to have_http_status(:not_found)
      end

      it 'returns 404 for an id that does not exist' do
        get '/api/v1/orders/999999', headers: headers

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe 'POST /api/v1/orders' do
    it 'returns 401 without a token' do
      post '/api/v1/orders', params: build_payload, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    context 'when authenticated' do
      it 'returns 201' do
        post_order
        expect(response).to have_http_status(:created)
      end

      it 'persists the order' do
        expect { post_order }.to change(Order, :count).by(1)
      end

      it 'returns customer_name in the body' do
        post_order
        expect(response.parsed_body['customer_name']).to eq('Juan Pérez')
      end

      it 'returns status pending in the body' do
        post_order
        expect(response.parsed_body['status']).to eq('pending')
      end

      it 'returns unit_price as a number' do
        post_order
        expect(response.parsed_body.dig('order_items', 0, 'unit_price')).to eq(150.0)
      end

      it 'deducts stock from the specified warehouse' do
        post_order
        expect(Stock.find_by(product: product, warehouse: warehouse).quantity).to eq(18)
      end

      it 'returns unit_price as a number, not a string' do
        post_order
        item = response.parsed_body['order_items'].first
        expect(item['unit_price']).to be_a(Numeric)
      end

      it 'assigns the company from the JWT' do
        post_order
        expect(Order.last.company_id).to eq(company.id)
      end

      it 'rejects when stock is insufficient' do
        post_order(build_payload(items: [default_item.merge(quantity: 50, unit_price: 10.00)]))
        expect(response).to have_http_status(:unprocessable_content)
      end

      it 'rejects when warehouse belongs to another company' do
        other_wh = other_company_warehouse
        post_order(build_payload(items: [default_item.merge(warehouse_id: other_wh.id)]))
        expect(response).to have_http_status(:unprocessable_content)
      end

      it 'rejects when order is not an object' do
        post '/api/v1/orders',
             params: { order: 'not_an_object' },
             headers: headers, as: :json
        expect(response).to have_http_status(:unprocessable_content)
      end

      it 'rejects when items is not an array' do
        post '/api/v1/orders',
             params: { order: { customer_name: 'X', items: 'not_an_array' } },
             headers: headers, as: :json
        expect(response).to have_http_status(:unprocessable_content)
      end

      it 'rejects when items is empty' do
        post '/api/v1/orders',
             params: { order: { customer_name: 'X', items: [] } },
             headers: headers, as: :json
        expect(response).to have_http_status(:unprocessable_content)
      end

      it 'rejects when items exceeds maximum' do
        too_many = (1..101).map { |i| default_item.merge(product_id: i) }
        post_order(build_payload(items: too_many))
        expect(response).to have_http_status(:unprocessable_content)
      end

      it 'returns 422 (not 404) when product does not exist' do
        post_order(build_payload(items: [default_item.merge(product_id: -1)]))
        expect(response).to have_http_status(:unprocessable_content)
      end

      it 'does not leak schema or tenant scope in the error body' do
        post_order(build_payload(items: [default_item.merge(product_id: -1)]))
        expect(response.parsed_body['error'])
          .to eq('product_id -1 does not exist')
      end

      it 'returns 400 when the order key is missing' do
        post '/api/v1/orders', params: {}, headers: headers, as: :json
        expect(response).to have_http_status(:bad_request)
      end

      it 'does not create order when item validation fails' do
        expect { post_order(build_payload(items: [default_item.merge(quantity: 50)])) }
          .not_to change(Order, :count)
      end

      it 'handles multiple items in a single order', :aggregate_failures do
        product2 = create_second_product
        post_order(build_payload(items: multi_item_payload(product, product2)))
        expect(response).to have_http_status(:created)
      end
    end
  end

  # ------------------------------------------------------------------ TESIS-114
  describe 'total_amount' do
    it 'comes back in the body of the order just created' do
      post_order

      expect(response.parsed_body['total_amount']).to eq(300.0)
    end

    it 'adds up every item of the order' do
      product2 = create_second_product
      post_order(build_payload(items: multi_item_payload(product, product2)))

      expect(response.parsed_body['total_amount']).to eq(750.0)
    end

    it 'is a number and not a string' do
      post_order

      expect(response.parsed_body['total_amount']).to be_a(Numeric)
    end

    it 'is not taken from the request body' do
      payload = build_payload
      payload[:order][:total_amount] = 999_999

      post_order(payload)

      expect(response.parsed_body['total_amount']).to eq(300.0)
    end

    it 'comes back in the detail' do
      post_order
      id = response.parsed_body['id']

      get "/api/v1/orders/#{id}", headers: headers

      expect(response.parsed_body['total_amount']).to eq(300.0)
    end

    # Es la columna Total del listado (TESIS-52): tiene que estar en la fila,
    # sin abrir el detalle.
    it 'comes back in each row of the list' do
      post_order

      get '/api/v1/orders', headers: headers

      expect(response.parsed_body['data'].first['total_amount']).to eq(300.0)
    end

    # Las órdenes anteriores a esta card sin líneas quedaron en NULL: el
    # listado tiene que devolverlas igual, con el campo vacío.
    it 'is null, without failing, for an order that has none' do
      make_order(items: 0)

      get '/api/v1/orders', headers: headers

      expect(response.parsed_body['data'].first['total_amount']).to be_nil
    end
  end

  # ------------------------------------------------------------------- TESIS-52
  # Las dos columnas del listado de órdenes que no salen de la propia orden:
  # «Destino», que se arma con la dirección del cliente, y «Operador logístico»,
  # que cuelga del envío.
  describe 'the columns of the orders screen' do
    def courier(name = 'Andreani')
      Service.create!(service_name: name, type: 'courier', http_method: 'POST',
                      uri: "https://api.#{name.downcase}.test/shipments")
    end

    def integration(service = courier)
      CompanyIntegration.create!(company: company, service: service)
    end

    def ship(order, company_integration: nil)
      Shipment.create!(company: company, order: order, status: 'pending',
                       company_integration: company_integration)
    end

    def located_order(address: 'Av. Rivadavia 1234', zip: '1406')
      Order.create!(company: company, customer_name: 'Juan Pérez', status: 'pending',
                    customer_address: address, customer_zip_code: zip)
    end

    def first_row
      get '/api/v1/orders', headers: headers
      response.parsed_body['data'].first
    end

    def ship_with_each_courier(names)
      names.each { |name| ship(make_order, company_integration: integration(courier(name))) }
    end

    describe 'the destination' do
      it 'returns the customer address' do
        located_order

        expect(first_row['customer_address']).to eq('Av. Rivadavia 1234')
      end

      it 'returns the zip code' do
        located_order

        expect(first_row['customer_zip_code']).to eq('1406')
      end

      # Ninguno de los dos campos es obligatorio en el modelo: una venta cargada
      # a mano puede no tener dirección y la fila tiene que viajar igual.
      it 'returns null for an order without an address, without failing' do
        make_order

        expect(first_row['customer_address']).to be_nil
      end

      # La pantalla ofrece buscar «por ID o destino», así que la dirección
      # entra en el buscador junto al id externo y al nombre del cliente.
      it 'is searchable' do
        located_order(address: 'Av. Rivadavia 1234')
        located_order(address: 'Calle Falsa 123')

        get '/api/v1/orders', params: { search: 'rivadavia' }, headers: headers

        expect(response.parsed_body['data'].pluck('customer_address'))
          .to eq(['Av. Rivadavia 1234'])
      end
    end

    describe 'the carrier' do
      it 'returns the name of the courier that carries the order' do
        ship(make_order, company_integration: integration)

        expect(first_row['carrier']).to eq('Andreani')
      end

      it 'is null when the order has no shipment yet' do
        make_order

        expect(first_row['carrier']).to be_nil
      end

      # El envío nace antes de que se sepa el courier: `company_integration` se
      # completa recién al confirmar el despacho.
      it 'is null when the shipment has no integration assigned' do
        ship(make_order)

        expect(first_row['carrier']).to be_nil
      end

      # Fija la precarga del controller. Sin `shipment: { company_integration:
      # :service }`, tres filas con envío son tres SELECT sobre services, y con
      # una página de veinte serían veinte.
      # Tres couriers distintos y no el mismo tres veces: una empresa no puede
      # tener dos integraciones contra el mismo servicio, y además así el
      # ejemplo no pasaría por casualidad si el preload agrupara mal.
      it 'resolves the courier of every row in a single query' do
        ship_with_each_courier(%w[Andreani Moova OCASA])

        queries = count_queries(matching: /FROM "services"/) do
          get '/api/v1/orders', headers: headers
        end

        expect(queries).to eq(1)
      end
    end
  end
end
