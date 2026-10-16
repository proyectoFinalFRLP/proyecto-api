# frozen_string_literal: true

# Tareas de desarrollo para conectar una empresa de los seeds con OCA e-Pak
# (TESIS-186), con el mismo patrón que las de Shopify (lib/tasks/integrations.rake).
# Las plantillas de OCA las siembra `db/seeds.rb`; la cuenta no: se carga acá.
#
# Lee del entorno, o de `.env` si no están seteadas (ver DevEnv):
#   OCA_<SLUG>_USR, OCA_<SLUG>_PSW                 usuario y contraseña de e-Pak
#   OCA_<SLUG>_CUIT                                con guiones
#   OCA_<SLUG>_NROCUENTA, OCA_<SLUG>_OPERATIVA, OCA_<SLUG>_CENTROCOSTO
#   OCA_<SLUG>_IDFRANJAHORARIA, OCA_<SLUG>_EMAIL   opcionales
# `.env.example` trae los valores de la cuenta de prueba pública de OCA.
#
#   bin/rails "integrations:oca:connect[norte]"
#   bin/rails "integrations:oca:test[norte]"
#   bin/rails "integrations:oca:smoke[norte]"
#
# La smoke recorre cotizar → despachar → etiqueta → seguimiento contra el
# entorno de PRUEBA de OCA, por los mismos casos de uso que la API. No corre en
# CI: sale a internet y crea una orden de retiro. La venta es inventada (un
# cliente ficticio en La Plata) y se crea sin tocar el stock: no pasa por el alta
# de órdenes, sólo existe para tener qué despachar.
module OcaDevTasks
  module_function

  DISPATCH_SERVICE = 'OCA e-Pak'
  QUOTE_SERVICE = 'OCA e-Pak - Cotización'
  # Nunca contra el productivo: el alta crea un retiro real.
  TEST_HOST = 'ocadev.com.ar'
  REQUIRED_SETTINGS = %w[CUIT NROCUENTA OPERATIVA CENTROCOSTO].freeze
  OPTIONAL_SETTINGS = %w[IDFRANJAHORARIA EMAIL].freeze

  # La integración que despacha (y con la que se sigue el envío y se pide la
  # etiqueta) y la que cotiza, que sólo necesita el CUIT y la operativa. Nacen
  # activas: es una tarea de desarrollo, y la cuenta se prueba enseguida.
  def connect(slug)
    abort 'Solo para desarrollo' unless Rails.env.development?

    company = company(slug)
    settings = settings(slug)
    dispatch = connect_service(company, DISPATCH_SERVICE, settings: settings,
                                                          credentials: { 'usr' => env(slug, 'USR'),
                                                                         'psw' => env(slug,
                                                                                      'PSW') })
    connect_service(company, QUOTE_SERVICE, settings: settings.slice('cuit', 'operativa'))

    puts "#{company.name} conectada a OCA e-Pak con la cuenta #{settings['nrocuenta']} " \
         "(integración ##{dispatch.id}). Credenciales guardadas cifradas."
  rescue Integrations::InvalidIntegrationError => e
    abort "Datos inválidos: #{e.fields}"
  end

  def test(slug)
    company = company(slug)
    Current.set(company_id: company.id) do
      result = Integrations::TestConnection.new(company_integration: dispatch_integration(company))
                                           .call
      puts "ok: #{result[:ok]} — #{result[:message]}"
    end
  end

  def env(slug, name) = DevEnv.fetch('OCA', slug, name)

  def settings(slug)
    required = REQUIRED_SETTINGS.to_h { |name| [name.downcase, env(slug, name)] }
    optional = OPTIONAL_SETTINGS.to_h { |name| [name.downcase, DevEnv.optional('OCA', slug, name)] }
    required.merge(optional.compact)
  end

  def connect_service(company, service_name, settings:, credentials: nil)
    Integrations::UpsertIntegration.new(
      company: company, service_id: Service.find_by!(service_name: service_name).id,
      credentials: credentials, settings: settings, is_active: true
    ).call
  end

  def company(slug)
    Company.find_by(slug: slug) || abort("No existe la empresa con slug #{slug}")
  end

  def dispatch_integration(company)
    integration = company.company_integrations.joins(:service)
                         .find_by(services: { service_name: DISPATCH_SERVICE })
    abort "#{company.name} no está conectada a OCA: integrations:oca:connect" if integration.nil?
    abort "#{DISPATCH_SERVICE} no apunta al entorno de prueba" unless
      integration.service.uri.include?(TEST_HOST)

    integration
  end
end

namespace :integrations do
  namespace :oca do
    desc 'Conecta la empresa [slug] con OCA e-Pak, con la cuenta de OCA_<SLUG>_* (solo desarrollo)'
    task :connect, [:slug] => :environment do |_task, args|
      OcaDevTasks.connect(args.fetch(:slug, 'norte'))
    end

    desc 'Prueba la conexión de OCA e-Pak de la empresa [slug]'
    task :test, [:slug] => :environment do |_task, args|
      OcaDevTasks.test(args.fetch(:slug, 'norte'))
    end

    desc 'Cotiza, despacha, baja la etiqueta y sigue un envío de [slug] contra OCA (prueba)'
    # OcaSmoke vive en lib/tasks/oca_smoke.rake.
    task :smoke, [:slug] => :environment do |_task, args|
      abort 'Solo para desarrollo' unless Rails.env.development?

      OcaSmoke.smoke(args.fetch(:slug, 'norte'))
    end
  end
end
