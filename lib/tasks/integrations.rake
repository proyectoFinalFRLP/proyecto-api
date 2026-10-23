# frozen_string_literal: true

# Tareas de desarrollo para conectar una empresa de los seeds con una tienda de
# prueba de Shopify sin pegar el client_secret en la consola ni en un request.
#
# Lee del entorno, o de `.env` si no están seteadas (Rails no carga `.env`):
#   SHOPIFY_<SLUG>_SHOP_DOMAIN    ej. onestock-norte.myshopify.com
#   SHOPIFY_<SLUG>_CLIENT_ID
#   SHOPIFY_<SLUG>_CLIENT_SECRET
#
#   bin/rails "integrations:shopify:connect[norte]"   (conecta y prueba la conexión)
#   bin/rails "integrations:shopify:test[norte]"
#   bin/rails "integrations:shopify:webhook[norte]"   (con PUBLIC_WEBHOOK_BASE_URL)
#   bin/rails "integrations:shopify:link[norte,NOR-001]"          (busca por SKU)
#   bin/rails "integrations:shopify:link[norte,NOR-001,4567890]"  (por id de variante)
#   bin/rails "integrations:shopify:resync[norte]"   (vuelve a publicar todo; también en producción)
#
# La lectura del entorno y de `.env` es la de DevEnv (lib/tasks/dev_env.rake),
# compartida con las tareas de OCA e-Pak (lib/tasks/oca.rake).

module ShopifyDevTasks
  module_function

  def connect(slug)
    abort 'Solo para desarrollo' unless Rails.env.development?

    company = company(slug)
    integration = Integrations::UpsertIntegration.new(
      company: company, service_id: shopify.id,
      credentials: { 'client_id' => setting(slug, 'CLIENT_ID'),
                     'client_secret' => setting(slug, 'CLIENT_SECRET') },
      settings: { 'shop_domain' => setting(slug, 'SHOP_DOMAIN') }
    ).call

    puts "#{company.name} conectada a #{integration.settings['shop_domain']} " \
         "(integración ##{integration.id}). Credenciales guardadas cifradas."
    # Sin la prueba, la integración quedaba sin ubicación de stock y el sync
    # saliente no publicaba nada (TESIS-177).
    test(slug)
  end

  # Prueba la conexión (completa la ubicación de stock) y dice si la
  # integración ya puede publicar el stock.
  def test(slug)
    company = company(slug)
    Current.set(company_id: company.id) do
      integration = company.company_integrations.find_by!(service: shopify)
      result = Integrations::TestConnection.new(company_integration: integration).call

      puts "ok: #{result[:ok]} — #{result[:message]}"
      puts "settings: #{integration.reload.settings.except(Integrations::TestConnection::OPTIONS_KEY)}"
      StockResyncTasks.report_readiness(integration)
    end
  end

  # Suscribe la tienda a las ventas: la dirección sale de
  # PUBLIC_WEBHOOK_BASE_URL (en desarrollo, la de un túnel).
  def webhook(slug)
    company = company(slug)
    Current.set(company_id: company.id) do
      integration = company.company_integrations.find_by!(service: shopify)
      result = Integrations::RegisterWebhook.new(company_integration: integration).call

      puts "ok: #{result[:ok]} — #{result[:message]}"
    end
  end

  # Vincula el producto (si no lo estaba) y publica su stock en el acto, sólo
  # en Shopify y sin esperar al worker, para ver el resultado en la tienda.
  def link(slug, sku, variant_id)
    company = company(slug)
    Current.set(company_id: company.id) do
      product = Product.find_by!(sku: sku)
      integration = company.company_integrations.find_by!(service: shopify)
      mapping = product.product_mappings.find_by(company_integration: integration) ||
                link_product(product, integration, variant_id)
      Catalog::OutboundSync.new(product: product, company_integration: integration).call

      puts "#{sku} vinculado a la variante #{mapping.external_product_id} " \
           "(#{mapping.external_refs}). Stock publicado en Shopify: #{product.total_stock}"
    end
  end

  def link_product(product, integration, variant_id)
    result = Catalog::LinkExternalProduct.new(product: product, company_integration: integration,
                                              external_product_id: variant_id).call
    result.warnings.each { |warning| puts "Aviso: #{warning}" }
    result.mapping
  end

  def shopify = Service.find_by!(service_name: 'Shopify')

  def company(slug)
    Company.find_by(slug: slug) || abort("No existe la empresa con slug #{slug}")
  end

  def setting(slug, name) = DevEnv.fetch('SHOPIFY', slug, name)
end

namespace :integrations do
  namespace :shopify do
    desc 'Conecta la empresa [slug] con su tienda de prueba de Shopify (solo desarrollo)'
    task :connect, [:slug] => :environment do |_task, args|
      ShopifyDevTasks.connect(args.fetch(:slug, 'norte'))
    end

    desc 'Vincula el producto [sku] de la empresa [slug] con Shopify y publica su stock'
    task :link, %i[slug sku variant_id] => :environment do |_task, args|
      ShopifyDevTasks.link(args.fetch(:slug, 'norte'), args.fetch(:sku), args[:variant_id])
    end

    desc 'Registra el webhook de ventas de Shopify de la empresa [slug]'
    task :webhook, [:slug] => :environment do |_task, args|
      ShopifyDevTasks.webhook(args.fetch(:slug, 'norte'))
    end

    desc 'Vuelve a publicar en Shopify el stock de los productos vinculados de la empresa [slug]'
    task :resync, [:slug] => :environment do |_task, args|
      StockResyncTasks.resync(args.fetch(:slug), service_name: 'Shopify')
    end

    desc 'Prueba la conexión de Shopify de la empresa [slug]'
    task :test, [:slug] => :environment do |_task, args|
      ShopifyDevTasks.test(args.fetch(:slug, 'norte'))
    end
  end
end
