# frozen_string_literal: true

require 'rails_helper'

# Contrato de la API con el frontend (TESIS-90).
#
# Los specs de cada recurso prueban que un campo **está**. Este archivo prueba
# algo distinto: que el conjunto de campos es EXACTAMENTE el acordado. La
# diferencia importa en las dos direcciones — quitar o renombrar un campo rompe
# al front en silencio hasta que alguien abre la pantalla, y agregarlo sin
# avisar deja la documentación mintiendo.
#
# Que un `expect` de acá falle no significa que el código esté mal: significa
# que el contrato cambió. La reparación es actualizar esta lista **a propósito**
# y el `api.ts` del front en el mismo momento.
#
# Las claves esperadas se escribieron leyendo las interfaces `Api*` de
# `proyecto-web` (`features/inventory/api.ts`, `features/orders/api.ts`), no los
# serializers: la idea es fijar lo que el consumidor asume, no repetir lo que el
# productor hace.
# El contrato, declarado de una vez. Cada ejemplo compara contra una de estas
# listas; cambiarlas es lo que significa cambiar el contrato.
CLAVES = {
  me: %w[id email company_id company created_at updated_at],
  empresa: %w[id name],
  producto_fila: %w[id sku name description category weight dimensions total_stock stock_status
                    in_transit_quantity primary_warehouse warehouse_count created_at updated_at],
  producto: %w[id sku name description category weight dimensions total_stock
               in_transit_quantity stocks created_at updated_at],
  stock: %w[id quantity warehouse_id warehouse created_at updated_at],
  deposito: %w[id name address zip_code],
  orden_fila: %w[id external_order_id customer_name customer_document customer_address
                 customer_zip_code customer_city customer_province status courier total_amount
                 item_count created_at updated_at],
  orden: %w[id external_order_id customer_name customer_document customer_address
            customer_zip_code customer_city customer_province status total_amount order_items
            created_at updated_at],
  linea: %w[id product_id warehouse_id quantity unit_price product created_at updated_at],
  courier: %w[id service_id name],
  envio: %w[id order_id status tracking_number shipping_label_url shipping_cost courier events
            created_at updated_at],
  evento: %w[id internal_status external_status description occurred_at created_at],
  meta: %w[page per_page total]
}.freeze

RSpec.describe 'API contract with the frontend', type: :request do
  let(:company) { Company.create!(name: 'Norte', tax_id: '30-11111111-1') }
  let(:user) { User.create!(email: 'norte@example.com', password: 'password123', company: company) }
  let(:headers) { auth_headers(user) }

  def auth_headers(for_user)
    post '/api/v1/auth/login',
         params: { email: for_user.email, password: 'password123' },
         headers: { 'X-Tenant-Slug' => for_user.company.slug }
    { 'Authorization' => "Bearer #{response.parsed_body['token']}" }
  end

  def warehouse
    @warehouse ||= Warehouse.create!(company: company, name: 'CD Norte', address: 'Av. 1',
                                     zip_code: '1900')
  end

  def product
    @product ||= begin
      p = Product.create!(company: company, sku: 'NOR-001', name: 'Servomotor', weight: 2.5)
      Stock.create!(product: p, warehouse: warehouse, quantity: 10)
      p
    end
  end

  def order
    @order ||= begin
      o = Order.create!(company: company, customer_name: 'Cliente', customer_address: 'Av. 2',
                        customer_zip_code: '1900', total_amount: 100)
      OrderItem.create!(order: o, product: product, quantity: 1, unit_price: 100)
      o
    end
  end

  def shipment
    @shipment ||= begin
      s = Shipment.create!(company: company, order: order, status: 'in_transit',
                           tracking_number: 'AND-1', shipping_cost: 500)
      ShipmentEvent.create!(shipment: s, internal_status: 'in_transit',
                            external_status: 'En camino', occurred_at: Time.current)
      s
    end
  end

  # ───────────────────────────────────────────────────────── forma del sobre
  #
  # Hoy la API responde con CUATRO formas distintas. No es una decisión: cada
  # card eligió la suya y nadie la escribió. TESIS-107 las unifica.
  #
  # Se fijan igual, y a propósito: mientras la inconsistencia exista, el front
  # tiene que saber cuál le toca a cada endpoint, y este archivo es el único
  # lugar donde eso está dicho. Cuando entre TESIS-107, estos cuatro ejemplos
  # son la lista de lo que hay que cambiar.
  describe 'the shape of the envelope, endpoint by endpoint' do
    it 'wraps a paginated collection in data plus meta', :aggregate_failures do
      product

      get '/api/v1/products', headers: headers

      expect(response.parsed_body.keys).to match_array(%w[data meta])
      expect(response.parsed_body['meta'].keys).to match_array(CLAVES[:meta])
    end

    # Sin `meta`: el listado no pagina. Es la mitad de TESIS-108.
    it 'wraps an unpaginated collection in data alone' do
      warehouse

      get '/api/v1/warehouses', headers: headers

      expect(response.parsed_body.keys).to eq(['data'])
    end

    it 'returns a single resource with no envelope at all' do
      get "/api/v1/products/#{product.id}", headers: headers

      expect(response.parsed_body.keys).to include('sku')
    end

    # El único endpoint que devuelve un array pelado, sin objeto que lo envuelva.
    it 'returns a bare array for the integrations listing' do
      get '/api/v1/integrations', headers: headers

      expect(response.parsed_body).to be_an(Array)
    end

    # Los errores sí son consistentes en toda la API, y conviene que siga así.
    it 'reports an error as a single error key' do
      get '/api/v1/products/999999', headers: headers

      expect(response.parsed_body.keys).to eq(['error'])
    end
  end

  # ──────────────────────────────────────────────── los campos que el front lee
  describe 'auth' do
    it 'answers the login with a token and nothing else' do
      post '/api/v1/auth/login',
           params: { email: user.email, password: 'password123' },
           headers: { 'X-Tenant-Slug' => company.slug }

      expect(response.parsed_body.keys).to eq(['token'])
    end

    # `/me` es la única fuente de la identidad de la sesión (TESIS-117): el
    # front dejó de mostrar el correo tipeado en el login y muestra éste.
    it 'answers /me with the identity and the company nested', :aggregate_failures do
      get '/api/v1/me', headers: headers

      expect(response.parsed_body.keys).to match_array(CLAVES[:me])
      expect(response.parsed_body['company'].keys).to match_array(CLAVES[:empresa])
    end
  end

  describe 'catalog' do
    it 'answers a row of the listing with the columns of the catalog screen' do
      product

      get '/api/v1/products', headers: headers

      expect(response.parsed_body['data'].first.keys).to match_array(CLAVES[:producto_fila])
    end

    # El detalle trae `stocks`, que el listado no incluye: es lo que separa una
    # pantalla de la otra y lo que el modal de edición necesita para poblarse.
    it 'answers the detail with the stock broken down by warehouse', :aggregate_failures do
      get "/api/v1/products/#{product.id}", headers: headers

      expect(response.parsed_body.keys).to match_array(CLAVES[:producto])
      expect(response.parsed_body['stocks'].first.keys).to match_array(CLAVES[:stock])
    end

    it 'answers a warehouse with the four fields the frontend declares' do
      warehouse

      get '/api/v1/warehouses', headers: headers

      expect(response.parsed_body['data'].first.keys).to match_array(CLAVES[:deposito])
    end
  end

  describe 'orders' do
    it 'answers a row of the listing with the columns of the orders screen' do
      order

      get '/api/v1/orders', headers: headers

      expect(response.parsed_body['data'].first.keys).to match_array(CLAVES[:orden_fila])
    end

    # El courier viaja con la misma forma acá y en los dos endpoints de envíos.
    # Que sea un objeto y no un string suelto salió de la review de TESIS-52.
    # El courier de una orden cuelga de su envío, así que hace falta despacharla.
    def courier_asignado
      service = Service.create!(service_name: "Andreani #{SecureRandom.hex(3)}", type: 'courier',
                                http_method: 'POST', uri: 'https://andreani.test/x')
      integration = CompanyIntegration.create!(company: company, service: service)
      Shipment.create!(company: company, order: order, status: 'pending',
                       company_integration: integration)
      service
    end

    it 'answers the courier of an order as an object', :aggregate_failures do
      service = courier_asignado

      get '/api/v1/orders', headers: headers

      courier = response.parsed_body['data'].first['courier']
      expect(courier.keys).to match_array(CLAVES[:courier])
      expect(courier['name']).to eq(service.service_name)
    end

    it 'answers the detail with its items and the product of each one', :aggregate_failures do
      get "/api/v1/orders/#{order.id}", headers: headers

      expect(response.parsed_body.keys).to match_array(CLAVES[:orden])
      expect(response.parsed_body['order_items'].first.keys).to match_array(CLAVES[:linea])
    end

    it 'answers a shipment with its log of events', :aggregate_failures do
      get "/api/v1/shipments/#{shipment.id}", headers: headers

      expect(response.parsed_body.keys).to match_array(CLAVES[:envio])
      expect(response.parsed_body['events'].first.keys).to match_array(CLAVES[:evento])
    end
  end

  # ────────────────────────────────────────────────── tipos, no sólo presencia
  #
  # Un campo puede estar y venir con el tipo equivocado. Los decimales son el
  # caso real: BigDecimal se serializa como string salvo que se lo convierta, y
  # un `"100.0"` donde el front espera un número rompe el formateo de moneda sin
  # que falte ninguna clave.
  describe 'the types of the fields that are not strings' do
    it 'sends the amounts of an order as numbers', :aggregate_failures do
      get "/api/v1/orders/#{order.id}", headers: headers

      expect(response.parsed_body['total_amount']).to be_a(Numeric)
      expect(response.parsed_body['order_items'].first['unit_price']).to be_a(Numeric)
    end

    it 'sends the weight of a product as a number' do
      get "/api/v1/products/#{product.id}", headers: headers

      expect(response.parsed_body['weight']).to be_a(Numeric)
    end

    it 'sends the cost of a shipment as a number' do
      get "/api/v1/shipments/#{shipment.id}", headers: headers

      expect(response.parsed_body['shipping_cost']).to be_a(Numeric)
    end

    it 'sends the pagination counters as numbers', :aggregate_failures do
      product

      get '/api/v1/products', headers: headers

      meta = response.parsed_body['meta']
      expect(meta['page']).to be_a(Numeric)
      expect(meta['total']).to be_a(Numeric)
    end
  end
end
