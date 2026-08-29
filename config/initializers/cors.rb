# Be sure to restart your server when you modify this file.

# Avoid CORS issues when API is called from the frontend app.
# Handle Cross-Origin Resource Sharing (CORS) in order to accept cross-origin Ajax requests.

# Read more: https://github.com/cyu/rack-cors

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins '*'
    resource '*',
             headers: :any,
             methods: %i[get post put patch delete options head],
             # Sin `expose`, el browser le oculta el ETag al JavaScript: CORS
             # sólo deja leer los headers simples salvo que el servidor los
             # liste. El front corre en otro origen (5173 contra 3000), así que
             # sin esta línea `response.headers.etag` llega `undefined`, el
             # modal no manda `If-Match` y el locking optimista de TESIS-101
             # queda desactivado sin que nada falle a la vista.
             expose: %w[ETag]
  end
end
