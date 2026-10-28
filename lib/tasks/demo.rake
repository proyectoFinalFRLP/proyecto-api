# frozen_string_literal: true

# Tareas de la demo (defensa del 2026-11-10).
#
#   bin/rails "demo:real_activity[norte,8]"
#     Vende y despacha con OCA (entorno de prueba) N órdenes de la empresa, por
#     los mismos casos de uso que la API (Demo::GenerateRealActivity). Se corre
#     una vez por día en desarrollo; en el entorno desplegado lo hace solo
#     Demo::RealActivityJob (config/recurring.yml) si DEMO_ACTIVITY_COMPANY lo
#     habilita.
#
#   bin/rails "demo:connect_oca[norte]"
#     Conecta la empresa con la cuenta de prueba PÚBLICA de OCA y pasa a OCA los
#     envíos de los couriers de ejemplo (db/seeds/demo_couriers.rb). En
#     desarrollo los seeds ya lo hacen; en el entorno desplegado no, a
#     propósito (ADR-022): se corre a mano, una vez.
#
#   bin/rails "demo:purge_seeded_history[norte]"
#   bin/rails "demo:purge_seeded_history[norte,dry_run]"
#     Borra la historia inventada que sembraba db/seeds/demo_activity.rb (ya no
#     existe) de una base sembrada antes. Sólo corre si se la llama: ninguna otra
#     tarea la invoca. Con `dry_run` sólo dice qué borraría.
#
# Ninguna sale del entorno de prueba de OCA: las plantillas apuntan a `ocadev`
# (db/seeds/oca.rb) y `connect_oca` se niega si alguien las cambió.
module DemoTasks
  module_function

  def real_activity(slug, count)
    company = OcaDevTasks.company(slug)
    OcaDevTasks.dispatch_integration(company)
    result = Demo::GenerateRealActivity.new(company: company, count: count).call
    abort "Nada que hacer: #{result.skipped}" if result.skipped

    result.outcomes.each { |outcome| puts line_for(outcome) }
    puts summary(result.outcomes)
    result.warnings.each { |warning| puts "Aviso: #{warning}" }
  end

  def line_for(outcome)
    case outcome.status
    when :dispatched
      "Orden ##{outcome.order_id} (#{outcome.customer}): OCA #{outcome.tracking_number}, " \
      "$#{format('%.2f', outcome.shipping_cost)} — cotizaciones #{outcome.quotes}"
    when :pending then "Orden ##{outcome.order_id} (#{outcome.customer}): queda sin despachar"
    else "#{outcome.order_id ? "Orden ##{outcome.order_id}" : 'Sin orden'}: " \
         "#{outcome.status} — #{outcome.error}"
    end
  end

  def summary(outcomes)
    by_status = outcomes.group_by(&:status).transform_values(&:size)
    cost = outcomes.filter_map(&:shipping_cost).sum
    "Resumen: #{outcomes.size} pedidas, #{by_status.fetch(:dispatched, 0)} despachadas, " \
      "#{by_status.fetch(:pending, 0)} pendientes, " \
      "#{outcomes.size - by_status.fetch(:dispatched, 0) - by_status.fetch(:pending, 0)} " \
      "con error. Costo de envío total: $#{format('%.2f', cost)}"
  end

  # La cuenta de prueba pública (OcaSeeds.demo_account) y no la de `.env`: es la
  # que sirve en cualquier entorno sin cargar secretos. Para otra cuenta está
  # `integrations:oca:connect`, sólo en desarrollo.
  def connect_oca(slug)
    load Rails.root.join('db/seeds/oca.rb')
    load Rails.root.join('db/seeds/demo_couriers.rb')
    company = OcaDevTasks.company(slug)
    abort 'La plantilla de OCA no apunta al entorno de prueba' unless
      OcaSeeds.base_uri.include?(OcaDevTasks::TEST_HOST)

    OcaSeeds.install!
    OcaSeeds.connect_demo!(company)
    integration = OcaDevTasks.dispatch_integration(company)
    DemoCouriers.retire!(company)
    puts "#{company.name} conectada a OCA (prueba, integración ##{integration.id}); " \
         'los couriers de ejemplo quedaron inactivos y sus envíos pasaron a OCA.'
  end
end

namespace :demo do
  desc 'Vende y despacha con OCA (prueba) [count] órdenes reales de la empresa [slug]'
  task :real_activity, %i[slug count] => :environment do |_task, args|
    DemoTasks.real_activity(args.fetch(:slug, 'norte'), Integer(args.fetch(:count, 8)))
  end

  desc 'Conecta la empresa [slug] con la cuenta de prueba pública de OCA y le pasa los envíos'
  task :connect_oca, [:slug] => :environment do |_task, args|
    DemoTasks.connect_oca(args.fetch(:slug, 'norte'))
  end

  # DemoHistoryPurge vive en lib/tasks/demo_purge.rake.
  desc 'Borra la historia inventada de los seeds viejos de la empresa [slug] ([slug,dry_run])'
  task :purge_seeded_history, %i[slug mode] => :environment do |_task, args|
    DemoHistoryPurge.purge(args.fetch(:slug), dry_run: args[:mode] == 'dry_run')
  end
end
