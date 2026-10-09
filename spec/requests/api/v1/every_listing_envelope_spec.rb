# frozen_string_literal: true

require 'rails_helper'

# ADR-015 recorrido sobre las rutas, no sobre una lista escrita a mano.
#
# `api_contract_spec.rb` fija la forma de los endpoints que enumera, y el ADR
# lo deja dicho: «un endpoint nuevo con otra forma no rompe nada hasta que se
# lo agrega ahí. Recorrer todas las rutas sería otra card». Esta es esa card.
#
# Toma de `Rails.application.routes` cada GET de `/api/v1` y lo clasifica:
#
# - un `index` es una colección: viaja en `data` + `meta` (`page`, `per_page`,
#   `total`), salvo los feeds acotados, que no paginan y van pelados;
# - los vocabularios fijos van en `data` sin `meta` (ADR-015, «Excepciones»);
# - los recursos sueltos (`show`, `me`, `tenant-config`) se prueban en sus
#   specs: acá sólo se verifica que estén clasificados.
#
# Una ruta GET nueva que no sea un `index` y no esté en ninguna lista hace
# fallar el spec: alguien tiene que decidir qué forma tiene.
#
# Las listas van en un módulo y no sueltas en el bloque: una constante de nivel
# superior en un spec es de `Object` para todo el proceso (mismo criterio que
# `ContratoDeLaApi`).
module FormaDeCadaRuta
  VOCABULARIOS = %w[products#categories orders#provinces].freeze
  # Feeds acotados: son `index` pero no paginan. `/activity` (TESIS-162) corta
  # en un límite duro y se lee entero de una vez, así que un `meta` con `page`
  # y `total` describiría una paginación que no existe. Van en `data` pelado,
  # como los vocabularios, y por eso se excluyen del barrido de colecciones.
  FEEDS = %w[activity#index].freeze
  # `reports#overview` (TESIS-999007) es un recurso calculado: va pelado. Está
  # anotado acá aunque la ruta llegue en otra rama, para que el orden de merge
  # no rompa este spec.
  # `products#counts` (TESIS-162) es un agregado calculado, como `reports#overview`:
  # devuelve los cuatro contadores de las pestañas del catálogo, no una colección.
  # `shipments#counts` (TESIS-165) es el mismo caso para las pestañas del
  # listado de envíos.
  RECURSOS = %w[me#show tenant_config#show warehouses#show products#show orders#show
                shipments#show reports#overview products#counts shipments#counts].freeze
end

RSpec.describe 'Every listing keeps the response envelope (ADR-015)', type: :request do
  let(:company) { Company.create!(name: 'Norte', tax_id: '30-11111111-1') }
  let(:user) { User.create!(email: 'norte@example.com', password: 'password123', company: company) }
  let(:headers) { auth_headers(user) }
  let(:product) do
    Current.set(company_id: company.id) do
      Product.create!(company: company, sku: 'ENV-1', name: 'Sobre')
    end
  end

  def auth_headers(for_user)
    post '/api/v1/auth/login', params: { email: for_user.email, password: 'password123' },
                               headers: { 'X-Tenant-Slug' => for_user.company.slug }
    { 'Authorization' => "Bearer #{response.parsed_body['token']}" }
  end

  # Las rutas GET de la API, como `controlador#acción` => path de ejemplo.
  def api_get_routes
    Rails.application.routes.routes.each_with_object({}) do |route, found|
      path = route.path.spec.to_s
      next unless route.verb == 'GET' && path.start_with?('/api/v1/')

      action = "#{route.defaults[:controller].delete_prefix('api/v1/')}##{route.defaults[:action]}"
      found[action] = path.delete_suffix('(.:format)')
    end
  end

  def listings
    api_get_routes.select do |action, _|
      action.end_with?('#index') && FormaDeCadaRuta::FEEDS.exclude?(action)
    end
  end

  def sample(path) = path.gsub(':product_id', product.id.to_s)

  it 'finds the listings it walks (so an empty walk cannot pass)' do
    expect(listings.keys).to include('orders#index', 'products#index', 'failed_events#index')
  end

  # `controlador#acción` => [status, claves del body, claves del meta].
  def shapes_of_listings
    listings.to_h do |action, path|
      get sample(path), headers: headers
      [action, [response.status, response.parsed_body.keys.sort, response.parsed_body['meta']&.keys&.sort]]
    end
  end

  it 'answers every listing with data plus a page, per_page and total meta' do
    expected = [200, %w[data meta], %w[page per_page total]]

    expect(shapes_of_listings).to all(satisfy { |_action, shape| shape == expected })
  end

  it 'answers every vocabulary and bounded feed with data and no meta', :aggregate_failures do
    bare = FormaDeCadaRuta::VOCABULARIOS + FormaDeCadaRuta::FEEDS
    api_get_routes.slice(*bare).each do |action, path|
      get path, headers: headers

      expect(response.parsed_body.keys).to eq(['data']), "#{action} should be a bare vocabulary"
    end
  end

  # Si falla, hay una ruta GET nueva sin clasificar: decidí si es una colección
  # (que sea un `index`), un vocabulario o un recurso, y sumala a su lista.
  it 'knows the shape of every other GET route' do
    unclassified = api_get_routes.keys.reject do |action|
      action.end_with?('#index') || FormaDeCadaRuta::VOCABULARIOS.include?(action) ||
        FormaDeCadaRuta::RECURSOS.include?(action)
    end

    expect(unclassified).to be_empty
  end
end
