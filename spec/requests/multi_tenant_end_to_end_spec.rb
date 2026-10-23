# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/seeds/oca').to_s

# El escenario más crítico del sistema, de punta a punta y con dos empresas a la
# vez (TESIS-95).
#
# Norte y Sur venden el MISMO producto: mismo SKU, publicado en Shopify con el
# MISMO id de variante, y cada una recibe una venta con el MISMO id de orden. Es
# lo peor que le puede pasar al aislamiento: todo lo que identifica a la venta
# coincide, y lo único que las separa es por qué integración entró. A partir de
# ahí se sigue cada venta por el camino real —webhook firmado, worker de
# ingesta, descuento de stock, sync saliente, envío, cotización y despacho con
# OCA— y se verifica que nada cruce de una empresa a la otra.
#
# TESIS-97/161 (tenant_isolation_spec.rb) ya barren el 404 ruta por ruta sobre
# registros armados a mano. Este spec es el complemento: los datos nacen del
# flujo real, así que si algún paso intermedio (el worker, el picking de stock,
# el adaptador del courier) termina con el tenant de la OTRA empresa, cae acá.
# Un tenant en nil no: esos pasos buscan por id o por integración y escriben
# `company_id` explícito, así que pasarían igual. Ese caso lo cubre el `raise`
# de `with_tenant` en los jobs.
RSpec.describe 'Two companies with the same SKU, from webhook to shipment', type: :request do
  include ActiveJob::TestHelper

  # Lo que las dos empresas tienen en común: es la gracia del escenario.
  def sku = 'NB-14'
  def variant_id = '67579271348457'
  def external_order_id = '18922194698473'

  # Lo que las distingue. Cada empresa conecta SU tienda y SU cuenta de OCA; las
  # cantidades vendidas son distintas para que un descuento cruzado se note en
  # el número y no sólo en qué fila cambió.
  def accounts
    @accounts ||= {
      norte: { shop: 'norte.myshopify.com', secret: 'shpss_NORTE', stock: 20, sold: 1,
               oca_user: 'test@oca.com.ar', cuit: '30-53625919-4' },
      sur: { shop: 'sur.myshopify.com', secret: 'shpss_SUR', stock: 7, sold: 3,
             oca_user: 'sur@oca.test', cuit: '30-22222222-2' }
    }
  end

  # ───────────────────────────────────────────────────────── las dos empresas
  #
  # Las empresas las da de alta el backoffice (ADR-017) y no un endpoint
  # público, así que nacen como registros. Todo lo demás —depósito, catálogo,
  # ventas, envíos— pasa por la API.
  def norte = @norte ||= Company.create!(name: 'Norte', tax_id: '30-11111111-1')
  def sur = @sur ||= Company.create!(name: 'Sur', tax_id: '30-33333333-3')
  def key_of(company) = company == norte ? :norte : :sur
  def account_of(company) = accounts.fetch(key_of(company))

  # Un usuario por empresa, que inicia sesión una sola vez.
  let(:sessions) { Hash.new { |cache, company| cache[company] = log_in(company) } }

  # Cada empresa conecta su propia app de Shopify, contra su propia tienda.
  let(:shops) { Hash.new { |cache, company| cache[company] = connect_shopify(company) } }

  # Una copia: el integration test de Rails escribe `X-Http-Method-Override`
  # en el Hash de headers que recibe, y si fuera el memoizado, los requests
  # siguientes de la empresa saldrían con otro verbo.
  def headers_of(company) = sessions[company].dup

  def log_in(company)
    user = User.create!(email: "admin@#{company.slug}.test", password: 'password123', company: company)
    post '/api/v1/auth/login', params: { email: user.email, password: 'password123' },
                               headers: { 'X-Tenant-Slug' => company.slug }
    { 'Authorization' => "Bearer #{response.parsed_body['token']}" }
  end

  # `CompanyScoped` pisa el `company:` explícito con el `Current.company_id` que
  # haya dejado un request anterior. Lo que se arma por fuera de la API se
  # arma sin tenant, y lo que se lee para verificar se lee como la empresa.
  def without_tenant(&) = Current.set(company_id: nil, &)
  def as(company, &) = Current.set(company_id: company.id, &)

  # ───────────────────────────────────────────────── canales e integraciones
  #
  # La plantilla de Shopify tal como la siembra db/seeds.rb: la ingesta del
  # webhook (response_mapper + firma) y el sync saliente de stock (GraphQL con
  # OAuth client credentials) salen de la misma.
  def shopify
    @shopify ||= Service.create!(
      service_name: 'Shopify', type: 'ecommerce', http_method: 'POST', request_format: 'graphql',
      uri: 'https://:shop_domain/admin/api/2026-07/graphql.json', **shopify_stock_sync,
      response_mapper: shopify_order_mapper,
      response_value_mapper: { 'authorized' => 'pending', 'voided' => 'cancelled' },
      webhook_config: { 'signature' => 'hmac_sha256_base64', 'signature_header' => 'X-Shopify-Hmac-SHA256',
                        'secret_key' => 'client_secret' }
    )
  end

  # El sync saliente: fija la cantidad `available` del inventory item, con un
  # token que se pide con el client id/secret de la app de cada empresa.
  def shopify_stock_sync
    {
      body_template: 'mutation SetStock($inventoryItemId: ID!, $locationId: ID!, $quantity: Int!, ' \
                     '$idempotencyKey: String!) { inventorySetQuantities(input: { name: "available", ' \
                     'reason: "correction", quantities: [{ inventoryItemId: $inventoryItemId, ' \
                     'locationId: $locationId, quantity: $quantity, changeFromQuantity: null }] }) ' \
                     '@idempotent(key: $idempotencyKey) { userErrors { code field message } } }',
      error_path: 'data.inventorySetQuantities.userErrors',
      auth_strategy: 'oauth_client_credentials',
      auth_config: { 'token_url' => 'https://:shop_domain/admin/oauth/access_token',
                     'token_header' => 'X-Shopify-Access-Token', 'token_prefix' => '' },
      request_mapper: { 'inventoryItemId' => 'inventory_item_id', 'locationId' => 'settings.location_id',
                        'quantity' => 'available_quantity', 'idempotencyKey' => 'idempotency_key' }
    }
  end

  # La ingesta: cómo se lee la venta del webhook `orders/create`.
  def shopify_order_mapper
    {
      'id' => 'external_order_id', 'name' => 'external_order_number', 'financial_status' => 'status',
      'shipping_address.name' => 'customer_name', 'shipping_address.address1' => 'customer_address',
      'shipping_address.zip' => 'customer_zip_code', 'shipping_address.city' => 'customer_city',
      'shipping_address.province' => 'customer_province', 'email' => 'customer_email',
      'line_items[].variant_id' => 'external_product_id', 'line_items[].quantity' => 'quantity',
      'line_items[].price' => 'unit_price'
    }
  end

  def shop_of(company) = shops[company]

  def connect_shopify(company)
    account = account_of(company)
    without_tenant do
      CompanyIntegration.create!(
        company: company, service: shopify, is_active: true,
        credentials: { 'client_id' => "CLIENT-#{company.slug}", 'client_secret' => account[:secret] },
        settings: { 'shop_domain' => account[:shop], 'location_id' => "gid://shopify/Location/#{company.slug}" }
      )
    end
  end

  # OCA con las plantillas de los seeds (db/seeds/oca.rb). Norte usa la cuenta
  # de prueba pública; Sur, una propia, para que cada pedido al courier diga con
  # qué cuenta salió.
  def connect_oca(company)
    return OcaSeeds.connect_demo!(company) if company == norte

    account = account_of(company)
    settings = OcaSeeds.demo_account[:settings].merge('cuit' => account[:cuit], 'nrocuenta' => '222222/001')
    [[OcaSeeds.dispatch, settings, { 'usr' => account[:oca_user], 'psw' => 'sur-secret' }],
     [OcaSeeds.quote, settings.slice('cuit', 'operativa'), nil]].each do |template, values, credentials|
      Integrations::UpsertIntegration.new(
        company: company, service_id: Service.find_by!(service_name: template[:service_name]).id,
        is_active: true, settings: values, credentials: credentials
      ).call
    end
  end

  def oca_dispatch_of(company)
    without_tenant do
      company.company_integrations.joins(:service).find_by!(services: { service_name: 'OCA' })
    end
  end

  # ──────────────────────────────────────────────── lo que contestan afuera
  #
  # Cada request saliente se guarda para poder preguntar después a quién se le
  # habló y con qué datos.
  def outbound = @outbound ||= Hash.new { |hash, key| hash[key] = [] }

  def stub_shop(company)
    shop = account_of(company)[:shop]
    stub_request(:post, "https://#{shop}/admin/oauth/access_token")
      .to_return(json(access_token: "TOKEN-#{company.slug}", expires_in: 86_399))
    stub_request(:post, "https://#{shop}/admin/api/2026-07/graphql.json").to_return do |request|
      outbound[shop] << JSON.parse(request.body)['variables']
      json(data: { inventorySetQuantities: { userErrors: [] } })
    end
  end

  def stub_oca(method, fixture)
    stub_request(:post, "#{OcaSeeds.base_uri}/#{method}").to_return do |request|
      sent = URI.decode_www_form(request.body).to_h
      outbound[method] << sent
      yield(oca_xml(fixture), sent)
    end
  end

  # Cada cuenta de OCA cotiza con su propio plazo, para que la fecha
  # comprometida de cada envío diga con qué cotización se despachó.
  def days_by_cuit = { accounts[:norte][:cuit] => 1, accounts[:sur][:cuit] => 4 }

  def quoted_days(reply, sent)
    reply.merge(body: reply[:body].sub('<PlazoEntrega>1<',
                                       "<PlazoEntrega>#{days_by_cuit.fetch(sent['Cuit'])}<"))
  end

  def json(body) = { status: 200, headers: { 'Content-Type' => 'application/json' }, body: body.to_json }

  # ──────────────────────────────────────────────────────────── el recorrido
  #
  # 1. Cada empresa arma su depósito y su catálogo por la API, con el mismo SKU.
  def build_catalog(company)
    post '/api/v1/warehouses', headers: headers_of(company), as: :json, params: {
      warehouse: { name: "Central #{company.name}", address: 'Calle 25 N° 456', zip_code: 'B1602',
                   city: 'Florida', province: 'Buenos Aires' }
    }
    post '/api/v1/products', headers: headers_of(company), as: :json, params: {
      product: { sku: sku, name: 'Notebook', weight: 1.5, length_cm: 32, width_cm: 22, height_cm: 2,
                 stocks: [{ warehouse_id: response.parsed_body['id'], quantity: account_of(company)[:stock] }] }
    }
    publish_on_shopify(company, response.parsed_body['id'])
  end

  # 2. El producto se publica en la tienda de cada una con el mismo id de
  # variante. El alta por la API consulta a Shopify (LinkExternalProduct, con
  # su propio spec); acá interesa el vínculo, no cómo se obtuvo.
  def publish_on_shopify(company, product_id)
    without_tenant do
      ProductMapping.create!(product: Product.unscoped.find(product_id), company_integration: shop_of(company),
                             external_product_id: variant_id,
                             external_refs: { 'inventory_item_id' => "gid://shopify/InventoryItem/#{company.slug}" })
    end
  end

  # 3. La venta entra por el webhook público de la integración, firmada con el
  # secreto de la tienda, y los workers corren en línea: la ingesta y el sync de
  # stock que ella encola.
  def deliver_sale(company, to: shop_of(company), secret: account_of(company)[:secret])
    payload = sale_payload(account_of(company)[:sold])
    signature = Base64.strict_encode64(OpenSSL::HMAC.digest('SHA256', secret, payload))
    perform_enqueued_jobs do
      post "/api/webhooks/integrations/#{to.id}",
           params: payload, headers: { 'CONTENT_TYPE' => 'application/json', 'X-Shopify-Topic' => 'orders/create',
                                       'X-Shopify-Hmac-SHA256' => signature }
    end
  end

  # Primero Norte, después Sur: la segunda venta llega con el mismo id de orden y
  # de variante que la primera, ya registrada.
  def deliver_both_sales = [norte, sur].each { |company| deliver_sale(company) }

  # La venta real capturada de la tienda de prueba (spec/fixtures/shopify), con
  # el SKU del escenario y la cantidad que vende cada empresa.
  def sale_payload(quantity)
    payload = JSON.parse(Rails.root.join('spec/fixtures/shopify/orders_create.json').read)
    payload['line_items'].each do |line|
      line.merge!('sku' => sku, 'quantity' => quantity, 'variant_id' => variant_id.to_i)
    end
    payload.to_json
  end

  # 4. Cada empresa abre el envío de su venta, lo cotiza y lo despacha con OCA.
  def ship(company)
    order_id = order_of(company).id
    post "/api/v1/orders/#{order_id}/shipment", headers: headers_of(company)
    shipment_id = response.parsed_body['id']
    post "/api/v1/orders/#{order_id}/quotes", headers: headers_of(company), as: :json,
                                              params: { quote: { origin_warehouse_id: warehouse_of(company).id } }
    option = response.parsed_body['data'].sole
    post "/api/v1/shipments/#{shipment_id}/dispatch", headers: headers_of(company), as: :json, params: {
      dispatch: { company_integration_id: option['dispatch_integration_id'],
                  origin_warehouse_id: warehouse_of(company).id, shipping_cost: option['shipping_cost'],
                  estimated_days: option['estimated_days'] }
    }
  end

  def order_of(company) = as(company) { Order.find_by!(external_order_id: external_order_id) }
  def product_of(company) = as(company) { Product.find_by!(sku: sku) }
  def warehouse_of(company) = as(company) { Warehouse.sole }
  def shipment_of(company) = as(company) { Shipment.includes(:company_integration).find_by!(order: order_of(company)) }
  def stock_of(company) = product_of(company).total_stock

  before do
    without_tenant do
      OcaSeeds.install!
      [norte, sur].each { |company| connect_oca(company) }
    end
    [norte, sur].each { |company| stub_shop(company) }
    stub_oca('Tarifar_Envio_Corporativo', 'quote') { |reply, sent| quoted_days(reply, sent) }
    stub_oca('IngresoORMultiplesRetiros_v2', 'dispatch') { |reply| reply }

    [norte, sur].each { |company| build_catalog(company) }
  end

  # ─────────────────────────────────────────────────────── la venta y el stock
  describe 'receiving the sale' do
    it 'deducts the stock of Norte only, while Sur has not sold yet', :aggregate_failures do
      deliver_sale(norte)
      expect(stock_of(norte)).to eq(19)
      expect(stock_of(sur)).to eq(7)
    end

    it 'deducts in each company exactly what that company sold', :aggregate_failures do
      deliver_both_sales
      expect(stock_of(norte)).to eq(19)
      expect(stock_of(sur)).to eq(4)
    end

    it 'registers each sale in the company whose channel received it, despite the same ids',
       :aggregate_failures do
      deliver_both_sales
      [norte, sur].each do |company|
        expect(order_of(company)).to have_attributes(company_id: company.id, company_integration_id: shop_of(company).id)
        expect(order_of(company).order_items.sole.product).to eq(product_of(company))
      end
    end

    it 'rejects a sale for Sur signed with the secret of Norte', :aggregate_failures do
      deliver_sale(norte, to: shop_of(sur))
      expect(response).to have_http_status(:unauthorized)
      expect(stock_of(sur)).to eq(7)
    end
  end

  # ─────────────────────────────────────────────────────────── el sync saliente
  describe 'publishing the new stock' do
    before { deliver_both_sales }

    # Una sola publicación por tienda: la de su empresa, con su item y su
    # ubicación. Si el sync cruzara, Norte recibiría también el 4 de Sur.
    def published_on(shop) = outbound[shop].map { |vars| vars.values_at('quantity', 'inventoryItemId', 'locationId') }

    it 'tells each shop only the stock of its own company', :aggregate_failures do
      expect(published_on('norte.myshopify.com'))
        .to eq([[19, 'gid://shopify/InventoryItem/norte', 'gid://shopify/Location/norte']])
      expect(published_on('sur.myshopify.com'))
        .to eq([[4, 'gid://shopify/InventoryItem/sur', 'gid://shopify/Location/sur']])
    end

    it 'authenticates against each shop with the token of its own app', :aggregate_failures do
      [norte, sur].each do |company|
        expect(WebMock).to have_requested(:post, "https://#{account_of(company)[:shop]}/admin/api/2026-07/graphql.json")
          .with(headers: { 'X-Shopify-Access-Token' => "TOKEN-#{company.slug}" }).once
      end
    end
  end

  # ───────────────────────────────────────────────── envío, cotización, despacho
  describe 'shipping each sale' do
    before do
      [norte, sur].each do |company|
        deliver_sale(company)
        ship(company)
      end
    end

    it 'leaves each shipment in its company, dispatched with its own courier', :aggregate_failures do
      [norte, sur].each do |company|
        expect(shipment_of(company)).to have_attributes(company_id: company.id, order_id: order_of(company).id,
                                                        status: 'ready_to_ship')
        expect(shipment_of(company).company_integration).to eq(oca_dispatch_of(company))
      end
    end

    it 'promises each shipment with the delivery days its own company was quoted', :aggregate_failures do
      [norte, sur].each do |company|
        expect(shipment_of(company).promised_delivery_on)
          .to eq(Shipment.promise_for(days_by_cuit.fetch(account_of(company)[:cuit])))
      end
    end

    it 'quotes each sale with the account of its own company' do
      expect(outbound['Tarifar_Envio_Corporativo'].pluck('Cuit')).to eq(%w[30-53625919-4 30-22222222-2])
    end

    it 'dispatches each sale with the account of its own company' do
      expect(outbound['IngresoORMultiplesRetiros_v2'].pluck('usr')).to eq(%w[test@oca.com.ar sur@oca.test])
    end

    # ─────────────────────────────────────── lo que ve cada usuario en pantalla
    def listed(path, company)
      get path, headers: headers_of(company)
      response.parsed_body['data']
    end

    it 'lists to each user only the orders, shipments and products of the company', :aggregate_failures do
      [norte, sur].each do |company|
        expect(listed('/api/v1/orders', company).pluck('id')).to eq([order_of(company).id])
        expect(listed('/api/v1/shipments', company).pluck('id')).to eq([shipment_of(company).id])
        expect(listed('/api/v1/products', company).pluck('id', 'total_stock')).to eq([[product_of(company).id, stock_of(company)]])
      end
    end

    it 'counts the tabs of each company with its own data only', :aggregate_failures do
      [norte, sur].each do |company|
        expect(listed('/api/v1/products/counts', company)).to include('all' => 1)
        expect(listed('/api/v1/shipments/counts', company)).to include('all' => 1, 'ready_to_ship' => 1)
      end
    end

    # Las ventas (de la curva: #132 sacó el KPI de órdenes), la facturación,
    # las unidades despachadas y el operador con que se despacharon, tal como
    # los lee la pantalla de Reportes.
    def overview_of(company)
      get '/api/v1/reports/overview', headers: headers_of(company)
      body = response.parsed_body
      [body['curve'].sum { |day| day['orders'] },
       *body['kpis'].values_at('revenue', 'dispatched_units').pluck('value'),
       body['carriers'].pluck('company_integration_id')]
    end

    it 'reports to each company its own sales and dispatched units', :aggregate_failures do
      expect(overview_of(norte)).to eq([1, 1_450_000.0, 1, [oca_dispatch_of(norte).id]])
      expect(overview_of(sur)).to eq([1, 4_350_000.0, 3, [oca_dispatch_of(sur).id]])
    end

    def dispatch_event_of(company)
      as(company) do
        ShipmentEvent.find_by!(shipment: shipment_of(company),
                               internal_status: Shipments::ConfirmDispatch::DISPATCHED_STATUS)
      end
    end

    it 'shows each company only its own activity', :aggregate_failures do
      [norte, sur].each do |company|
        expect(listed('/api/v1/activity', company).pluck('id'))
          .to contain_exactly("order-#{order_of(company).id}", "dispatch-#{dispatch_event_of(company).id}")
      end
    end

    # ───────────────────────────────────────────────── el intento de cruzarse
    #
    # Norte conoce los ids de Sur (son secuenciales) y prueba usarlos en cada
    # paso del recorrido. Todo tiene que contestar 404: ni los datos ni un 403
    # que confirme que existen.
    def crossings
      order = order_of(sur).id
      shipment = shipment_of(sur).id
      [[:get, "/api/v1/orders/#{order}", {}], [:get, "/api/v1/shipments/#{shipment}", {}],
       [:get, "/api/v1/products/#{product_of(sur).id}", {}], [:get, "/api/v1/shipments/#{shipment}/label", {}],
       [:post, "/api/v1/orders/#{order}/quotes", { quote: { origin_warehouse_id: warehouse_of(norte).id } }],
       [:post, "/api/v1/shipments/#{shipment}/dispatch", own_dispatch(norte)],
       [:post, "/api/v1/shipments/#{pending_shipment_of(norte)}/dispatch", own_dispatch(norte, courier: sur)]]
    end

    # Un envío de Norte todavía sin despachar, para que el cruce con el OCA de
    # Sur no pueda contestar 409 por el estado antes de buscar el courier.
    def pending_shipment_of(company)
      post '/api/v1/orders', headers: headers_of(company), as: :json, params: {
        order: { customer_name: 'Ana Gómez', customer_address: 'Calle 7 N° 1200', customer_zip_code: '1900',
                 customer_city: 'La Plata', customer_province: 'Buenos Aires',
                 items: [{ product_id: product_of(company).id, warehouse_id: warehouse_of(company).id,
                           quantity: 1, unit_price: 1000 }] }
      }
      post "/api/v1/orders/#{response.parsed_body.fetch('id')}/shipment", headers: headers_of(company)
      response.parsed_body.fetch('id')
    end

    def own_dispatch(company, courier: company)
      { dispatch: { company_integration_id: oca_dispatch_of(courier).id, origin_warehouse_id: warehouse_of(company).id } }
    end

    # El 404 tiene que ser el de la app (RecordNotFound) y no el del router: uno
    # por una ruta o un verbo mal armados pasaría sin probar el aislamiento.
    it 'answers 404 when Norte reaches for anything of Sur', :aggregate_failures do
      crossings.each do |verb, path, params|
        public_send(verb, path, headers: headers_of(norte), params: params, as: :json)
        expect(response).to have_http_status(:not_found), "#{verb.upcase} #{path} answered #{response.status}"
        expect(response.parsed_body).to eq('error' => 'Not found'), "#{verb.upcase} #{path} answered #{response.body}"
      end
    end

    it 'crosses with a shipment of Norte that is still pending' do
      expect(as(norte) { Shipment.find(pending_shipment_of(norte)).status }).to eq('pending')
    end
  end
end
