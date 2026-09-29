# Be sure to restart your server when you modify this file.

# Avoid CORS issues when API is called from the frontend app.
# Handle Cross-Origin Resource Sharing (CORS) in order to accept cross-origin Ajax requests.

# Read more: https://github.com/cyu/rack-cors

# Sólo el front puede llamar a la API desde un navegador (TESIS-130, ADR-018).
# Con `origins '*'`, cualquier página podía hacerlo: por ejemplo, repartir intentos
# de login entre los navegadores de sus visitantes, cada uno con su IP, y esquivar
# el límite por IP de TESIS-82.
#
# Los orígenes salen de CORS_ALLOWED_ORIGINS, separados por comas, y la variable
# es obligatoria en producción (config/environments/production.rb). Como cada
# empresa entra por su subdominio, se acepta un comodín para ese nivel:
# `https://*.precision-logistics.duckdns.org` vale para norte., sur., etc., pero no
# para a.b. ni para el dominio sin subdominio. rack-cors compara los strings tal
# cual, así que el comodín se traduce a una regex anclada.
#
# Sin la variable (desarrollo y test) se acepta localhost en cualquier puerto: el
# dev server de Vite (5173), `vite preview` o el contenedor de nginx del front.
cors_origins = ENV.fetch('CORS_ALLOWED_ORIGINS', '').split(',').map(&:strip).reject(&:empty?)
cors_origins.map! do |origin|
  next origin unless origin.include?('*')

  /\A#{Regexp.escape(origin).sub('\*', '[a-z0-9-]+')}\z/
end
if cors_origins.empty? && !Rails.env.production?
  cors_origins = [%r{\Ahttp://(localhost|127\.0\.0\.1)(:\d+)?\z}]
end

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins(*cors_origins)
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
