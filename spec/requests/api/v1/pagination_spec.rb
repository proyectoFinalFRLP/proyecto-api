# frozen_string_literal: true

require 'rails_helper'

# Los bordes de la paginación, una vez y no por endpoint (TESIS-108).
#
# El cálculo vive en `Api::V1::Paginatable` y lo comparten todos los listados,
# así que se prueba sobre uno —productos, que es el que más filas tiene en los
# ejemplos— y aparte se verifica que los demás lo usen.
#
# Lo que estos ejemplos protegen es que un número raro se **acote** en vez de
# romper: un `page=0` se traduce a un offset negativo, que es un error de SQL, y
# un `per_page=9999` es una respuesta que nadie pidió.
RSpec.describe 'Pagination', type: :request do
  let(:company) { Company.create!(name: 'Norte', tax_id: '30-11111111-1') }
  let(:user) { User.create!(email: 'n@example.com', password: 'password123', company: company) }
  let(:headers) { auth_headers(user) }

  def auth_headers(for_user)
    post '/api/v1/auth/login',
         params: { email: for_user.email, password: 'password123' },
         headers: { 'X-Tenant-Slug' => for_user.company.slug }
    { 'Authorization' => "Bearer #{response.parsed_body['token']}" }
  end

  def create_products(count)
    count.times { |i| Product.create!(company: company, sku: "NOR-#{i}", name: "Producto #{i}") }
  end

  def meta_for(params)
    get '/api/v1/products', params: params, headers: headers
    response.parsed_body['meta']
  end

  def rows_for(params)
    get '/api/v1/products', params: params, headers: headers
    response.parsed_body['data']
  end

  describe 'the page number' do
    it 'defaults to the first page' do
      expect(meta_for({})['page']).to eq(1)
    end

    # Un offset negativo es un error de SQL: se acota en vez de romper.
    it 'clamps page zero to the first page' do
      expect(meta_for(page: 0)['page']).to eq(1)
    end

    it 'clamps a negative page to the first page' do
      expect(meta_for(page: -3)['page']).to eq(1)
    end

    it 'reads a page that is not a number as the first one' do
      expect(meta_for(page: 'dos')['page']).to eq(1)
    end

    # Una página más allá del final no es un error: es una página vacía.
    it 'answers an empty page past the end, with the real total', :aggregate_failures do
      create_products(3)

      expect(rows_for(page: 99)).to be_empty
      expect(meta_for(page: 99)['total']).to eq(3)
    end
  end

  describe 'the page size' do
    it 'defaults to twenty rows' do
      expect(meta_for({})['per_page']).to eq(Api::V1::Paginatable::DEFAULT_PER_PAGE)
    end

    it 'honours a size the caller asked for' do
      expect(meta_for(per_page: 5)['per_page']).to eq(5)
    end

    # El techo es lo que impide que un listado devuelva la tabla entera.
    it 'never goes above the ceiling, however large the request' do
      expect(meta_for(per_page: 9999)['per_page']).to eq(Api::V1::Paginatable::MAX_PER_PAGE)
    end

    it 'clamps a size of zero to one row' do
      expect(meta_for(per_page: 0)['per_page']).to eq(1)
    end

    it 'clamps a negative size to one row' do
      expect(meta_for(per_page: -5)['per_page']).to eq(1)
    end

    it 'reads a size that is not a number as one row' do
      expect(meta_for(per_page: 'todas')['per_page']).to eq(1)
    end

    it 'returns exactly the rows it says it returns' do
      create_products(7)

      expect(rows_for(per_page: 3).length).to eq(3)
    end
  end

  describe 'the total' do
    it 'counts the whole scope and not the page', :aggregate_failures do
      create_products(7)

      get '/api/v1/products', params: { per_page: 3 }, headers: headers

      expect(response.parsed_body['data'].length).to eq(3)
      expect(response.parsed_body['meta']['total']).to eq(7)
    end
  end

  # Antes esto era el cálculo copiado en cuatro controllers y ausente en otros
  # tres. Si alguien agrega un listado que no pagina, o vuelve a copiar el
  # cálculo, este bloque lo delata.
  describe 'every listing of the API' do
    def warehouse
      Warehouse.create!(company: company, name: 'CD Norte', address: 'Av. 1', zip_code: '1900')
    end

    def listings
      product = Product.create!(company: company, sku: 'NOR-X', name: 'Producto')
      warehouse
      ['/api/v1/products', '/api/v1/warehouses', '/api/v1/orders', '/api/v1/shipments',
       '/api/v1/failed-events', '/api/v1/integrations', '/api/v1/stock-transfers',
       "/api/v1/products/#{product.id}/mappings"]
    end

    def meta_of(path)
      get path, headers: headers
      response.parsed_body['meta']
    end

    it 'answers with a meta that carries page, per_page and total', :aggregate_failures do
      listings.each do |path|
        expect(meta_of(path)&.keys).to match_array(%w[page per_page total]),
                                       "#{path} no trae el meta esperado"
      end
    end

    it 'respects the ceiling everywhere', :aggregate_failures do
      listings.each do |path|
        get path, params: { per_page: 9999 }, headers: headers

        expect(response.parsed_body['meta']['per_page']).to eq(Api::V1::Paginatable::MAX_PER_PAGE),
                                                            "#{path} se pasa del techo"
      end
    end
  end
end
