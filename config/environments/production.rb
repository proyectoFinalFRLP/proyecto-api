require 'active_support/core_ext/integer/time'

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Sin estas variables la API no arranca en producción (TESIS-130, ADR-018).
  # Sin ellas, el JWT se firmaría con secret_key_base, el Host no se validaría y
  # CORS no dejaría pasar al front: las dos primeras dejan la puerta abierta sin
  # que nada falle a la vista, y la tercera rompe el front sin decir por qué.
  # Que el contenedor no levante es mejor que cualquiera de las tres.
  # SECRET_KEY_BASE_DUMMY marca el `assets:precompile` del Dockerfile, que
  # arranca la app en el build, cuando todavía no hay secretos del entorno.
  unless ENV['SECRET_KEY_BASE_DUMMY']
    missing = %w[DEVISE_JWT_SECRET_KEY CORS_ALLOWED_ORIGINS RAILS_ALLOWED_HOSTS].select do |name|
      ENV[name].blank?
    end
    if missing.any?
      raise "Missing environment variables for production: #{missing.join(', ')} (see ADR-018)"
    end
  end

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { 'cache-control' => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = :local

  # El TLS termina en el proxy (Caddy), que también redirige HTTP a HTTPS: a Rails
  # le llega HTTP plano. assume_ssl hace que tome esos requests como HTTPS, y
  # force_ssl suma Strict-Transport-Security y marca las cookies como Secure,
  # entre ellas la de la sesión del backoffice (TESIS-130, ADR-018).
  config.assume_ssl = true
  config.force_ssl = true

  # Skip http-to-https redirect for the default health check endpoint.
  # config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [:request_id]
  config.logger   = ActiveSupport::TaggedLogging.logger($stdout)

  # Change to "debug" to log everything (including potentially personally-identifiable information!).
  config.log_level = ENV.fetch('RAILS_LOG_LEVEL', 'info')

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = '/up'

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Replace the default in-process memory cache store with a durable alternative.
  config.cache_store = :solid_cache_store

  # Replace the default in-process and non-durable queuing backend for Active Job.
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  # Ignore bad email addresses and do not raise email delivery errors.
  # Set this to true and configure the email server for immediate delivery to raise delivery errors.
  # config.action_mailer.raise_delivery_errors = false

  # Set host to be used by links generated in mailer templates.
  config.action_mailer.default_url_options = { host: 'example.com' }

  # Specify outgoing SMTP server. Remember to add smtp/* credentials via bin/rails credentials:edit.
  # config.action_mailer.smtp_settings = {
  #   user_name: Rails.application.credentials.dig(:smtp, :user_name),
  #   password: Rails.application.credentials.dig(:smtp, :password),
  #   address: "smtp.example.com",
  #   port: 587,
  #   authentication: :plain
  # }

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [:id]

  # Enable DNS rebinding protection and other `Host` header attacks.
  # config.hosts = [
  #   "example.com",     # Allow requests from example.com
  #   /.*\.example\.com/ # Allow requests from subdomains like `www.example.com`
  # ]

  # Despliegue en contenedor detrás de un proxy TLS (Caddy + DuckDNS): el Host
  # que ve Rails es el subdominio público de la API. Los hosts salen de
  # RAILS_ALLOWED_HOSTS, separados por comas, y la variable es obligatoria
  # (ver arriba): sin lista, Rails no valida el Host en producción. Con ella, un
  # request con otro Host recibe 403 (TESIS-120, TESIS-130).
  config.hosts.concat(ENV.fetch('RAILS_ALLOWED_HOSTS', '').split(',').map(&:strip).reject(&:empty?))

  # El health check de /up llega con el Host que use quien lo haga (la IP del
  # contenedor, localhost), no con el público: validarlo lo daría por caído.
  config.host_authorization = { exclude: ->(request) { request.path == '/up' } }
end
