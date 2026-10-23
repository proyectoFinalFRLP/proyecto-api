# frozen_string_literal: true

module Catalog
  # El estado de la publicación del stock de cada integración, para la pantalla
  # de integraciones de la empresa (GET /api/v1/integrations, TESIS-177):
  #
  # - `ready`: si puede publicar (no le falta configuración).
  # - `missing_settings`: lo que le falta, con el nombre con el que lo declara
  #   la plantilla (en Shopify, la ubicación de stock).
  # - `failing_products`: cuántos vínculos fallaron en su último intento.
  # - `last_sync_error`: el motivo del fallo más reciente, si hay alguno.
  # - `last_synced_at`: el último intento, salga bien o mal.
  #
  # Una integración cuya plantilla no publica stock no tiene estado (nil). Lee
  # los vínculos en tres consultas para todas las integraciones juntas.
  class StockSyncStatus < ApplicationPoro
    def initialize(integrations)
      super()
      @integrations = integrations.to_a
    end

    # { company_integration_id => estado | nil }
    def call
      return {} if @integrations.empty?

      @integrations.to_h { |integration| [integration.id, status_of(integration)] }
    end

    private

    def status_of(integration)
      requirements = StockPublishRequirements.new(integration.service)
      return unless requirements.publishes_stock?

      missing = requirements.missing_settings(integration.settings)
      { 'ready' => missing.empty?, 'missing_settings' => missing,
        'failing_products' => failing_counts.fetch(integration.id, 0),
        'last_sync_error' => last_errors[integration.id],
        'last_synced_at' => last_attempts[integration.id] }
    end

    def mappings = ProductMapping.where(company_integration_id: @integrations.map(&:id))

    def failing_counts
      @failing_counts ||= mappings.where.not(last_sync_error: nil)
                                  .group(:company_integration_id).count
    end

    def last_attempts
      @last_attempts ||= mappings.group(:company_integration_id).maximum(:last_synced_at)
    end

    # El error del vínculo que falló más recientemente, uno por integración.
    def last_errors
      @last_errors ||= mappings.where.not(last_sync_error: nil)
                               .select('DISTINCT ON (company_integration_id) ' \
                                       'company_integration_id, last_sync_error')
                               .order(:company_integration_id, last_synced_at: :desc)
                               .to_h { [it.company_integration_id, it.last_sync_error] }
    end
  end
end
