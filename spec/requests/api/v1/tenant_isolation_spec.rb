# frozen_string_literal: true

require 'rails_helper'

# Aislamiento entre empresas, visto desde el lado del que intenta romperlo
# (TESIS-97).
#
# Los specs de cada recurso ya prueban que un id ajeno devuelve 404. Este archivo
# no los repite: enuncia la garantía UNA vez y la barre sobre todos los recursos,
# de modo que un endpoint nuevo que se olvide de `policy_scope` caiga acá aunque
# su propio spec no lo contemple. Y cubre los tres caminos que ningún spec de
# recurso mira, porque no son de un recurso sino de la arquitectura: el
# `company_id` del cuerpo, el del token, y los webhooks, que no llevan sesión.
RSpec.describe 'Tenant isolation and abuse cases', type: :request do
  let(:company) { Company.create!(name: 'Norte', tax_id: '30-11111111-1') }
  let(:user) { User.create!(email: 'norte@example.com', password: 'password123', company: company) }
  let(:headers) { auth_headers(user) }

  def auth_headers(for_user)
    post '/api/v1/auth/login',
         params: { email: for_user.email, password: 'password123' },
         headers: { 'X-Tenant-Slug' => for_user.company.slug }
    { 'Authorization' => "Bearer #{response.parsed_body['token']}" }
  end

  def intruder_company
    @intruder_company ||= Company.create!(name: 'Sur', tax_id: '30-22222222-2')
  end

  # `assign_current_company` de CompanyScoped pisa el `company:` explícito cuando
  # `Current.company_id` quedó seteado por un request anterior. Forzarlo a nil es
  # lo que garantiza que el fixture nazca SIEMPRE en la otra empresa.
  def as_intruder(&)
    Current.set(company_id: nil, &)
  end

  # ─────────────────────────────────────────────────────────── recursos ajenos
  #
  # Un registro de cada tipo, propiedad de la otra empresa, con lo mínimo para
  # existir. Se crean por demanda: la mayoría de los ejemplos usa uno solo.
  def other_warehouse
    @other_warehouse ||= as_intruder do
      Warehouse.create!(company: intruder_company, name: 'CD Sur', address: 'Calle 1', zip_code: '2000')
    end
  end

  def other_product
    @other_product ||= as_intruder do
      Product.create!(company: intruder_company, sku: 'SUR-001', name: 'Producto de Sur')
    end
  end

  def other_order
    @other_order ||= as_intruder do
      Order.create!(company: intruder_company, customer_name: 'Cliente de Sur',
                    customer_address: 'Calle 2', customer_zip_code: '2000')
    end
  end

  def other_shipment
    @other_shipment ||= as_intruder do
      Shipment.create!(company: intruder_company, order: other_order, status: 'pending')
    end
  end

  def other_failed_event
    @other_failed_event ||= as_intruder do
      FailedEvent.create!(company: intruder_company, event_type: 'integrations.http_request',
                          next_retry_at: 1.minute.from_now)
    end
  end

  def other_integration
    @other_integration ||= as_intruder do
      courier_integration(company: intruder_company, name: 'Andreani Sur', is_active: true)
    end
  end

  # Una transferencia en vuelo de la otra empresa. Necesita un segundo depósito
  # suyo: el modelo rechaza que el origen y el destino sean el mismo.
  def other_transfer
    @other_transfer ||= as_intruder do
      destination = Warehouse.create!(company: intruder_company, name: 'CD Sur 2',
                                      address: 'Calle 3', zip_code: '2000')
      StockTransfer.create!(company: intruder_company, product: other_product,
                            origin_warehouse: other_warehouse, destination_warehouse: destination,
                            quantity: 1, dispatched_at: Time.current)
    end
  end

  # ─────────────────────────────────────────────────────────────────── IDOR
  #
  # Un id existente pero de otra empresa tiene que responder 404, no 403: un 403
  # confirmaría que el recurso existe, que es justo lo que no se quiere decir.
  # El 404 deja al intruso sin saber si adivinó un id válido.
  describe 'guessing the id of a resource that belongs to another company' do
    # Verbos que cada recurso expone sobre un id ajeno. Se arma desde una lista
    # por recurso —y no ruta por ruta— para que agregar un endpoint sea una
    # entrada más y no otra línea de `expect`.
    def rutas_ajenas
      producto = other_product.id
      deposito = other_warehouse.id
      orden = other_order.id
      evento = other_failed_event.id
      transferencia = other_transfer.id

      [
        [%i[get put delete], "/api/v1/products/#{producto}"],
        [%i[get put delete], "/api/v1/warehouses/#{deposito}"],
        [%i[get], "/api/v1/orders/#{orden}"],
        [%i[get], "/api/v1/shipments/#{other_shipment.id}"],
        [%i[post], "/api/v1/orders/#{orden}/shipment"],
        [%i[post], "/api/v1/orders/#{orden}/quotes"],
        [%i[get], "/api/v1/products/#{producto}/mappings"],
        [%i[post], "/api/v1/failed-events/#{evento}/retry"],
        [%i[post], "/api/v1/failed-events/#{evento}/discard"],
        [%i[post], "/api/v1/stock-transfers/#{transferencia}/receive"],
        [%i[post], "/api/v1/stock-transfers/#{transferencia}/cancel"]
      ].flat_map { |verbos, ruta| verbos.map { |verbo| [verbo, ruta] } }
    end

    it 'answers 404 on every route, never 403', :aggregate_failures do
      rutas_ajenas.each do |verbo, ruta|
        public_send(verbo, ruta, headers: headers)

        expect(response).to have_http_status(:not_found),
                            "#{verbo.upcase} #{ruta} devolvió #{response.status} y no 404"
      end
    end

    # Sin esto el barrido de arriba no distingue el 404 del scope del 404 del
    # router: en test `show_exceptions = :rescuable` hace que una ruta que no
    # existe también responda 404, así que una ruta mal escrita —o renombrada
    # más adelante— lo dejaría en verde sin cubrir nada. Acá falla, y falla
    # diciendo cuál.
    it 'sweeps routes that exist', :aggregate_failures do
      rutas_ajenas.each do |verbo, ruta|
        expect { Rails.application.routes.recognize_path(ruta, method: verbo) }
          .not_to raise_error, "#{verbo.upcase} #{ruta} no corresponde a ninguna ruta"
      end
    end

    # La otra mitad de la contraprueba: que el 404 tampoco venga de la sesión ni
    # de un request mal armado, sino de quién es el dueño del recurso.
    it 'answers 200 on the same route for a resource of its own company' do
      own = Product.create!(company: company, sku: 'NOR-001', name: 'Producto de Norte')

      get "/api/v1/products/#{own.id}", headers: headers

      expect(response).to have_http_status(:ok)
    end

    # El listado no devuelve 404 —existe y es suyo— pero tampoco puede filtrar
    # una fila ajena. Es el otro lado del mismo aislamiento.
    context 'with a row of each company in the same table' do
      before do
        other_product
        other_order
        other_transfer
        Product.create!(company: company, sku: 'NOR-002', name: 'Propio')
      end

      # Lo que un listado devuelve, identificado por el campo que lo distingue.
      def filas_de(ruta, campo)
        get ruta, headers: headers
        response.parsed_body['data'].pluck(campo)
      end

      it 'never leaks the row of the other company in a listing', :aggregate_failures do
        expect(filas_de('/api/v1/products', 'sku')).to eq(['NOR-002'])
        expect(filas_de('/api/v1/orders', 'id')).to be_empty
        expect(filas_de('/api/v1/stock-transfers', 'id')).to be_empty
      end
    end
  end

  # ────────────────────────────────────────────── company_id en el cuerpo
  #
  # `CompanyScoped` fuerza el company_id del contexto al crear y lo vuelve
  # inmutable en updates, así que un `company_id` en el body no es un error de
  # validación: se ignora. Estos ejemplos fijan que se ignore y no que se acepte.
  describe 'sending a company_id of another company in the body' do
    it 'ignores it when creating a warehouse' do
      post '/api/v1/warehouses',
           params: { warehouse: { name: 'CD Propio', address: 'Av. 1', zip_code: '1900',
                                  company_id: intruder_company.id } },
           headers: headers

      expect(Warehouse.unscoped.find(response.parsed_body['id']).company_id).to eq(company.id)
    end

    # La orden es el alta más compleja —descuenta stock y crea líneas— así que
    # es donde más fácil se cuela un company_id que no corresponde.
    # Una línea vendible propia: sin stock la orden se rechaza antes de llegar a
    # la asignación de empresa, que es lo que este ejemplo quiere mirar.
    def linea_propia
      warehouse = Warehouse.create!(company: company, name: 'CD Norte', address: 'Av. 5',
                                    zip_code: '1900')
      product = Product.create!(company: company, sku: 'NOR-010', name: 'Para vender')
      Stock.create!(product: product, warehouse: warehouse, quantity: 5)
      { product_id: product.id, quantity: 1, unit_price: 100, warehouse_id: warehouse.id }
    end

    def orden_con_company_ajeno
      { order: { customer_name: 'Cliente', customer_address: 'Av. 2', customer_zip_code: '1900',
                 company_id: intruder_company.id, items: [linea_propia] } }
    end

    it 'ignores it when creating an order' do
      post '/api/v1/orders', params: orden_con_company_ajeno, headers: headers, as: :json

      expect(Order.unscoped.find(response.parsed_body['id']).company_id).to eq(company.id)
    end

    # El update es el caso que más importa: crear en la empresa equivocada es
    # ruido, pero MOVER un registro propio a otra empresa lo haría desaparecer
    # para su dueño y aparecer para el intruso.
    it 'does not move an existing warehouse to another company' do
      own = Warehouse.create!(company: company, name: 'CD Norte', address: 'Av. 3', zip_code: '1900')

      put "/api/v1/warehouses/#{own.id}",
          params: { warehouse: { name: 'CD Renombrado', company_id: intruder_company.id } },
          headers: headers

      expect(own.reload.company_id).to eq(company.id)
    end
  end

  # ───────────────────────────────────────────── company_id en el token
  #
  # El JWT lleva `company_id` en su payload (User#jwt_payload), pero la
  # aplicación NO lo lee: `Current.company_id` sale de `current_user.company_id`,
  # es decir de la fila del usuario en la base. Manipular el claim no cambia nada.
  #
  # Que la firma impida forjar un token es propiedad de la librería y no hace
  # falta re-probarla; lo que sí importa acá es que, aun si alguien lograra
  # firmar uno, el claim no es la fuente del tenant.
  describe 'a token whose company_id claim points at another company' do
    let(:forged_token) do
      secret = ENV.fetch('DEVISE_JWT_SECRET_KEY') { Rails.application.secret_key_base }
      original = decode_jwt(headers['Authorization'].delete_prefix('Bearer '))
      JWT.encode(original.merge('company_id' => intruder_company.id), secret, 'HS256')
    end

    let(:forged_headers) { { 'Authorization' => "Bearer #{forged_token}" } }

    it 'still resolves the tenant from the user, not from the claim' do
      other_product
      own = Product.create!(company: company, sku: 'NOR-003', name: 'Propio')

      get '/api/v1/products', headers: forged_headers

      expect(response.parsed_body['data'].pluck('sku')).to eq([own.sku])
    end

    it 'still answers 404 for a resource of the company named in the claim' do
      get "/api/v1/products/#{other_product.id}", headers: forged_headers

      expect(response).to have_http_status(:not_found)
    end

    it 'creates in the company of the user and not in the one of the claim' do
      post '/api/v1/warehouses',
           params: { warehouse: { name: 'CD', address: 'Av. 4', zip_code: '1900' } },
           headers: forged_headers

      expect(Warehouse.unscoped.find(response.parsed_body['id']).company_id).to eq(company.id)
    end
  end

  # ─────────────────────────────────────────────────────────────── webhooks
  #
  # Los webhooks no llevan sesión: el proveedor externo no tiene cómo
  # autenticarse. El tenant sale del `company_integration_id` de la URL, así que
  # cualquiera puede empujar un evento a cualquier integración cuyo id adivine.
  # Eso es el diseño. Lo que no puede pasar es que la respuesta le devuelva algo
  # del otro tenant, ni que el evento termine atribuido a otra empresa.
  describe 'the webhook endpoints, which carry no authentication' do
    it 'answers 202 with an empty body, telling the caller nothing', :aggregate_failures do
      post "/api/webhooks/couriers/#{other_integration.id}",
           params: { status: 'in_transit' }.to_json,
           headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:accepted)
      expect(response.body).to be_empty
    end

    # El log se atribuye a la empresa de la integración, que es un dato del
    # servidor, y no a nada que el que llama pueda elegir.
    it 'files the event under the company of the integration' do
      post "/api/webhooks/couriers/#{other_integration.id}",
           params: { status: 'in_transit', company_id: company.id }.to_json,
           headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(WebhookLog.unscoped.order(:id).last.company_id).to eq(intruder_company.id)
    end

    # Un id de integración que no existe responde 404 y no 202: no hay a quién
    # atribuirle el evento. Sigue sin revelar nada de ninguna empresa.
    it 'answers 404 for an integration that does not exist', :aggregate_failures do
      post '/api/webhooks/couriers/999999',
           params: { status: 'in_transit' }.to_json,
           headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body.to_s).not_to include(intruder_company.name)
    end
  end
end
