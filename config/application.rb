require_relative 'boot'

require 'rails/all'

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module ProyectoApi
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Only loads a smaller set of middleware suitable for API only apps.
    # Middleware like session, flash, cookies can be added back manually.
    # Skip views, helpers and assets when generating a new resource.
    config.api_only = true

    # Middlewares mínimos para el backoffice de /admin (Avo necesita sesión,
    # cookies y flash). La API JWT sigue siendo stateless: no usa sesión.
    #
    # Van antes de Warden::Manager, como en una app Rails completa. Con `use`
    # quedaban después, porque Devise registra Warden al cargarse. Cuando Warden
    # corta un request con `throw :warden` (el vencimiento de la sesión, por
    # ejemplo), el throw se salteaba el commit de la sesión: el cierre por
    # inactividad no llegaba a la cookie y el navegador entraba en un loop de
    # redirecciones (TESIS-129).
    config.middleware.insert_before Warden::Manager, ActionDispatch::Cookies
    config.middleware.insert_before Warden::Manager, ActionDispatch::Session::CookieStore,
                                    key: '_proyecto_api_session'
    config.middleware.insert_before Warden::Manager, ActionDispatch::Flash
    config.middleware.use Rack::MethodOverride

    # La URL pública HTTPS con la que los proveedores llegan a la API: la del
    # servidor en producción, la de un túnel en desarrollo. Es con lo que se
    # arma la dirección del webhook que se le registra a cada proveedor
    # (Integrations::RegisterWebhook). No sale del host del request: el registro
    # corre desde el backoffice o la consola, y lo que importa es cómo nos ve el
    # proveedor, no cómo entró el administrador.
    config.x.public_webhook_base_url = ENV['PUBLIC_WEBHOOK_BASE_URL'].presence&.chomp('/')
  end
end
