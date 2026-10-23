# frozen_string_literal: true

module Catalog
  # Vuelve a publicar en un canal el stock de sus productos vinculados
  # (TESIS-177): después de completar la configuración que faltaba (la
  # ubicación de stock de Shopify), o desde el «Reintentar» de un vínculo que
  # falló.
  #
  # Encola un SyncStockToChannelsJob por producto, acotado a ese canal: no
  # vuelve a publicar en los demás. El total se calcula cuando corre el job,
  # así que se publica el stock vigente.
  #
  # Antes de encolar se fija que el canal pueda publicar
  # (StockPublishRequirements): si a la integración le falta configuración,
  # levanta ChannelNotReadyError y no encola nada, porque todos los jobs
  # fallarían igual. Un vínculo sin las referencias que hacen falta no se
  # encola: se devuelve con su motivo, para volver a vincularlo.
  class ResyncChannel < ApplicationPoro
    # `enqueued`: cuántos productos se encolaron. `skipped`: { mapping_id =>
    # motivo } de los vínculos que no.
    Result = Struct.new(:enqueued, :skipped)

    def initialize(company_integration:, mappings: nil)
      super()
      @integration = company_integration
      @mappings = mappings || company_integration.product_mappings
    end

    def call
      ensure_channel_ready!
      ready, incomplete = @mappings.to_a.partition { |mapping| refs_problem(mapping).nil? }
      ActiveJob.perform_all_later(ready.map { |mapping| job_for(mapping) })
      Result.new(ready.size, incomplete.to_h { |mapping| [mapping.id, refs_problem(mapping)] })
    end

    private

    def requirements
      @requirements ||= StockPublishRequirements.new(@integration.service)
    end

    def ensure_channel_ready!
      problem = channel_problem
      raise ChannelNotReadyError, problem if problem
    end

    def channel_problem
      name = @integration.service_name
      return "#{name} does not publish stock" unless requirements.publishes_stock?
      return "the #{name} integration is inactive" unless @integration.is_active

      requirements.setting_problem(@integration.settings)
    end

    def refs_problem(mapping) = requirements.refs_problem(mapping.external_refs)

    def job_for(mapping)
      SyncStockToChannelsJob.new(mapping.product_id, @integration.company_id, @integration.id)
    end
  end
end
