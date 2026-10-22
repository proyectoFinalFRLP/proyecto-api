# frozen_string_literal: true

# Vuelve a publicar el stock de los productos vinculados de una empresa
# (TESIS-177). Corre en producción: después de completar la ubicación de stock
# de Shopify, o de un incidente que dejó al canal desalineado.
#
#   bin/rails "integrations:resync_stock[norte]"     (todos los canales activos)
#   bin/rails "integrations:shopify:resync[norte]"   (sólo Shopify, en integrations.rake)
#
# Encola un job por producto y canal (Catalog::ResyncChannel): el stock que se
# publica es el vigente cuando corre el job. Hace falta que los workers estén
# corriendo (en el deploy, SOLID_QUEUE_IN_PUMA=1).
#
# Es un `.rake` y no un `.rb` por lo mismo que DevEnv (lib/tasks/dev_env.rake):
# Rake lo carga con el resto de las tareas.
module StockResyncTasks
  module_function

  def resync(slug, service_name: nil)
    company = Company.find_by(slug: slug) || abort("No existe la empresa con slug #{slug}")
    Current.set(company_id: company.id) do
      integrations = company.company_integrations.includes(:service).where(is_active: true)
      integrations = integrations.joins(:service).where(services: { service_name: }) if service_name
      abort "#{company.name} no tiene integraciones activas para publicar" if integrations.empty?

      integrations.each { |integration| resync_integration(integration) }
    end
  end

  def resync_integration(integration)
    return unless requirements(integration).publishes_stock?

    result = Catalog::ResyncChannel.new(company_integration: integration).call
    puts "#{integration.service_name}: #{result.enqueued} productos encolados."
    result.skipped.each do |mapping_id, problem|
      puts "  vínculo ##{mapping_id} salteado: #{problem}"
    end
  rescue Catalog::ChannelNotReadyError => e
    puts "#{integration.service_name}: no se encoló nada. #{e.message}"
  end

  def report_readiness(integration)
    problem = requirements(integration).setting_problem(integration.settings)
    puts problem ? "NO puede publicar el stock: #{problem}" : 'Lista para publicar el stock.'
  end

  def requirements(integration) = Catalog::StockPublishRequirements.new(integration.service)
end

namespace :integrations do
  desc 'Vuelve a publicar el stock de los productos vinculados de la empresa [slug] en ' \
       'todos sus canales activos'
  task :resync_stock, [:slug] => :environment do |_task, args|
    StockResyncTasks.resync(args.fetch(:slug))
  end
end
