# frozen_string_literal: true

module Catalog
  # Propaga el stock consolidado de un producto a todos los canales donde está
  # publicado (un ProductMapping por canal), usando la plantilla y las
  # credenciales de cada integración a través del HttpAdapter genérico.
  #
  # Corre siempre dentro de un job: las APIs externas son lentas y pueden estar
  # caídas, así que nunca debe colgarse del request del usuario.
  class OutboundSync < ApplicationPoro
    def initialize(product:)
      super()
      @product = product
    end

    def call
      return if mappings.empty?

      # Un canal caído no puede frenar la propagación al resto: se intenta con
      # todos y recién al final se levanta el fallo acumulado.
      failures = mappings.filter_map { |mapping| push_to(mapping) }
      raise_aggregated(failures) if failures.any?
    end

    private

    # Sólo los canales activos: una integración dada de baja puede tener
    # credenciales revocadas y no debe recibir tráfico.
    def mappings
      @mappings ||= @product.product_mappings
                            .joins(:company_integration)
                            .where(company_integrations: { is_active: true })
                            .includes(company_integration: :service)
                            .to_a
    end

    # Devuelve nil si el envío salió bien y el error si falló, para que el
    # filter_map de #call se quede sólo con los fallos.
    def push_to(mapping)
      Integrations::HttpAdapter.new(
        company_integration: mapping.company_integration,
        payload: { external_id: mapping.external_product_id, available_quantity: total_stock },
        uri_params: { external_id: mapping.external_product_id }
      ).call
      nil
    rescue Integrations::AdapterExecutionError => e
      e
    end

    # El total se calcula al ejecutar, no al encolar: si el stock volvió a
    # cambiar mientras el job esperaba en la cola, se publica el valor vigente.
    def total_stock
      @total_stock ||= @product.total_stock
    end

    # Se re-levanta como AdapterExecutionError (y no como un error propio) para
    # que ApplicationJob lo reconozca como fallo transitorio de API externa y
    # reintente el job con espera creciente.
    def raise_aggregated(failures)
      raise Integrations::AdapterExecutionError.new(
        "outbound sync failed for #{failures.size} of #{mappings.size} channels: " \
        "#{failures.map { |failure| failure_detail(failure) }.join('; ')}",
        payload: { product_id: @product.id, available_quantity: total_stock }
      )
    end

    # response_status es nil para fallos de red (timeout, conexión rechazada);
    # se agrega al mensaje sólo cuando la plataforma respondió con un código.
    def failure_detail(failure)
      return failure.message unless failure.response_status

      "#{failure.message} (status #{failure.response_status})"
    end
  end
end
