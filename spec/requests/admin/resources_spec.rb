# frozen_string_literal: true

require 'rails_helper'

# Barrido del panel de administración (TESIS-93).
#
# Los recursos de Avo son bloques `fields` que no se evalúan hasta que alguien
# abre la página: un campo mal nombrado, una asociación que ya no existe o un
# `self.title` que apunta a un método borrado no rompen ningún test de la suite
# —rompen la pantalla, y recién cuando se entra—. Hasta esta card, de los ocho
# recursos sólo se abría el de servicios.
#
# Esto abre el listado y el detalle de cada uno con una fila de verdad. No
# verifica cómo se ve: verifica que la página se arme, que es la parte que hoy
# nadie miraba y la que decide si la demo del panel funciona.
RSpec.describe 'Admin panel resources (Avo)', type: :request do
  let(:admin_user) { AdminUser.create!(email: 'admin@backoffice.com', password: 'admin123') }
  let(:company) { Company.create!(name: 'Distribuidora Norte', tax_id: '30-11111111-1') }

  # Una fila por tabla, todas de la misma empresa. El tenant se setea a mano:
  # CompanyScoped toma el company_id del contexto y acá no hay request de API
  # que lo haya puesto.
  #
  # Memoizado: cada ejemplo abre varias páginas sobre las MISMAS filas.
  let(:rows) { seed }

  def seed
    Current.company_id = company.id

    warehouse = Warehouse.create!(company: company, name: 'Central', zip_code: '1900',
                                  address: 'Av. 1')
    product = Product.create!(company: company, sku: 'NOR-001', name: 'Celular')
    stock = Stock.create!(product: product, warehouse: warehouse, quantity: 10)
    user = User.create!(email: 'operador@norte.test', password: 'password123', company: company)
    integration = courier_integration(company: company)
    order = Order.create!(company: company, customer_name: 'Juan Pérez', status: 'paid',
                          external_order_id: 'ML-1001')
    shipment = Shipment.create!(company: company, company_integration: integration, order: order,
                                tracking_number: 'AND-123', status: 'in_transit')

    { companies: company, warehouses: warehouse, products: product, stocks: stock, users: user,
      company_integrations: integration, orders: order, shipments: shipment }
  ensure
    Current.reset
  end

  # Login por el formulario y no con el helper `sign_in`: ese helper usa
  # `Warden.on_next_request`, que vale para UN request. Estos ejemplos abren
  # ocho páginas seguidas, así que necesitan la sesión de verdad —la misma que
  # usa un administrador— o la segunda página ya contesta un redirect al login.
  before do
    post '/admin/sign_in',
         params: { admin_user: { email: admin_user.email, password: 'admin123' } }
  end

  after { Current.reset }

  describe 'every resource of the panel' do
    it 'renders the listing', :aggregate_failures do
      rows.each_key do |resource|
        get "/admin/resources/#{resource}"

        expect(response).to have_http_status(:ok), "el listado de #{resource} no abre"
      end
    end

    it 'renders the detail of a row', :aggregate_failures do
      rows.each do |resource, record|
        get "/admin/resources/#{resource}/#{record.id}"

        expect(response).to have_http_status(:ok), "el detalle de #{resource} no abre"
      end
    end

    it 'renders the create form', :aggregate_failures do
      rows.each_key do |resource|
        get "/admin/resources/#{resource}/new"

        expect(response).to have_http_status(:ok), "el alta de #{resource} no abre"
      end
    end

    it 'renders the edit form', :aggregate_failures do
      rows.each do |resource, record|
        get "/admin/resources/#{resource}/#{record.id}/edit"

        expect(response).to have_http_status(:ok), "el formulario de #{resource} no abre"
      end
    end
  end

  # Los diccionarios de una plantilla se editan como JSON. La columna es jsonb,
  # así que puede contener un objeto —lo normal— o un string, y el panel tiene
  # que mostrar los dos: el string tal cual, el objeto formateado. Sólo se
  # ejercitaba el segundo (TESIS-93).
  describe 'the JSON dictionaries of a service' do
    let(:service) do
      Service.create!(service_name: 'Andreani', type: 'courier', http_method: 'POST',
                      uri: 'https://api.andreani.test/ordenes',
                      request_mapper: { 'destino.cp' => 'customer_zip_code' })
    end

    # La validación del modelo no deja guardar un diccionario que no sea objeto,
    # así que la única forma de tener esa fila es saltearla —que es justo lo que
    # pudo pasar con una fila vieja o un import—.
    def store_bare_string_mapper
      service.update_column(:request_mapper, 'un-string-suelto') # rubocop:disable Rails/SkipsModelValidations
    end

    it 'shows a dictionary stored as an object' do
      get "/admin/resources/services/#{service.id}"

      expect(response.body).to include('customer_zip_code')
    end

    it 'opens the form of a dictionary that holds a bare string' do
      store_bare_string_mapper

      get "/admin/resources/services/#{service.id}/edit"

      expect(response).to have_http_status(:ok)
    end

    it 'shows that string as it is, without formatting it as JSON' do
      store_bare_string_mapper

      get "/admin/resources/services/#{service.id}/edit"

      expect(response.body).to include('un-string-suelto')
    end
  end

  # El buscador de cada recurso. Esto es lo que destapó que las tres búsquedas
  # del panel —empresas, productos y usuarios— levantaban NameError: el lambda
  # usaba `search_term` y Avo 4 entrega lo tipeado como `q`. Como no había
  # ningún ejemplo que buscara, el panel se veía sano hasta que alguien
  # escribía en la caja (TESIS-93).
  describe 'the search box of each resource' do
    it 'answers instead of raising', :aggregate_failures do
      rows

      %w[companies products users].each do |resource|
        get "/admin/resources/#{resource}?q=zzz-no-existe"

        expect(response).to have_http_status(:ok), "la búsqueda de #{resource} no anda"
      end
    end

    it 'finds a product by a piece of its name' do
      rows

      get '/admin/resources/products?q=Celu'

      expect(response.body).to include('NOR-001')
    end

    it 'finds a product by its sku' do
      rows

      get '/admin/resources/products?q=NOR-001'

      expect(response.body).to include('Celular')
    end

    it 'finds a company by its tax id' do
      rows

      get '/admin/resources/companies?q=30-11111111-1'

      expect(response.body).to include('Distribuidora Norte')
    end

    it 'finds a user by a piece of its email' do
      rows

      get '/admin/resources/users?q=operador'

      expect(response.body).to include('operador@norte.test')
    end

    it 'leaves out what does not match' do
      rows

      get '/admin/resources/products?q=zzz-no-existe'

      expect(response.body).not_to include('NOR-001')
    end
  end

  # Un envío recién creado: el número de seguimiento lo devuelve el courier al
  # despachar, así que hasta entonces la fila no lo tiene.
  def shipment_without_tracking
    Current.company_id = company.id
    order = Order.create!(company: company, customer_name: 'Ana', status: 'paid')
    Shipment.create!(company: company, order: order, status: 'pending',
                     company_integration: rows[:company_integrations])
  end

  # El título de cada fila es un método del modelo, no una columna. Son los que
  # arma Avo para el breadcrumb y para los selects de las asociaciones: si uno
  # devuelve nil o levanta, la pantalla que lo muestra se cae.
  describe 'the label each row shows in the panel' do
    it 'names an order by its customer and external id' do
      order = rows[:orders]

      expect(order.display_name).to eq('Juan Pérez (ML-1001)')
    end

    # `customer_name` es NOT NULL en la base y tiene validación, así que una
    # orden guardada siempre lo trae: el fallback es para la fila todavía sin
    # guardar, que es la que el panel muestra en el formulario de alta.
    it 'falls back to the id on an order that is not saved yet' do
      expect(Order.new.display_name).to eq('Order #')
    end

    it 'names an order without external id by its customer alone' do
      Current.company_id = company.id
      manual = Order.create!(company: company, customer_name: 'Ana', status: 'pending')

      expect(manual.display_name).to eq('Ana')
    end

    it 'names a stock row by its product and warehouse' do
      expect(rows[:stocks].display_name).to eq('Celular @ Central')
    end

    it 'names a shipment by its tracking number' do
      expect(rows[:shipments].display_name).to eq('AND-123')
    end

    # Un envío recién creado todavía no tiene número: el courier lo devuelve al
    # despachar. Hasta entonces el panel lo nombra por su id.
    it 'falls back to the id when the shipment has no tracking number yet' do
      pending_shipment = shipment_without_tracking

      expect(pending_shipment.display_name).to eq("Shipment ##{pending_shipment.id}")
    end

    # Las filas todavía sin asociar: el formulario de alta las muestra antes de
    # que el administrador elija empresa o servicio. El `&.` de cada etiqueta es
    # lo que evita que esa pantalla se caiga.
    it 'survives an integration that has no company nor service yet' do
      expect(CompanyIntegration.new.display_name).to eq(' ↔ ')
    end

    it 'survives a stock row that has no product nor warehouse yet' do
      expect(Stock.new.display_name).to eq(' @ ')
    end

    it 'names an integration by the company and the service' do
      integration = rows[:company_integrations]

      expect(integration.display_name).to eq("Distribuidora Norte \u2194 Andreani")
    end
  end
end
