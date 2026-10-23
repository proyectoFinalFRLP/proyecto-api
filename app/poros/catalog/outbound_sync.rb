# frozen_string_literal: true

module Catalog
  # Propaga el stock consolidado de un producto a todos los canales donde está
  # publicado (un ProductMapping por canal), usando la plantilla y las
  # credenciales de cada integración a través del HttpAdapter genérico.
  #
  # Corre siempre dentro de un job: las APIs externas son lentas y pueden estar
  # caídas, así que nunca debe colgarse del request del usuario.
  #
  # Antes de llamar al canal se fija que la integración y el vínculo tengan lo
  # que el pedido necesita (StockPublishRequirements, TESIS-177): sin eso el
  # pedido sale incompleto y el proveedor lo rechaza con un error que no dice
  # qué falta (Shopify: `Variable $locationId of type ID! was provided invalid
  # value`).
  #
  # Cada vínculo guarda el resultado de su último intento (`last_synced_at`,
  # `last_sync_error`): es lo que muestra el detalle del producto.
  class OutboundSync < ApplicationPoro
    MAX_ERROR_LENGTH = 1000

    # `company_integration` acota la propagación a un solo canal: al vincular un
    # producto hay que alinear ese canal, no volver a publicar en todos.
    def initialize(product:, company_integration: nil)
      super()
      @product = product
      @integration = company_integration
    end

    def call
      return if mappings.empty?

      # Un canal caído no puede frenar la propagación al resto: se intenta con
      # todos y recién al final se levanta el fallo acumulado.
      failures = mappings.filter_map { |mapping| record(mapping, push_to(mapping)) }
      raise_aggregated(failures) if failures.any?
    end

    private

    # Sólo los canales activos (una integración dada de baja puede tener
    # credenciales revocadas y no debe recibir tráfico) y que saben publicar
    # stock (Service#stock_template).
    def mappings
      @mappings ||= scoped_mappings.joins(:company_integration)
                                   .where(company_integrations: { is_active: true })
                                   .includes(company_integration: :service)
                                   .select { |mapping| requirements(mapping).publishes_stock? }
    end

    def scoped_mappings
      mappings = @product.product_mappings
      @integration ? mappings.where(company_integration: @integration) : mappings
    end

    def requirements(mapping)
      @requirements ||= {}
      service = mapping.company_integration.service
      @requirements[service.id] ||= StockPublishRequirements.new(service)
    end

    # Devuelve nil si el envío salió bien y el error si falló, para que el
    # filter_map de #call se quede sólo con los fallos.
    def push_to(mapping)
      problem = not_ready_problem(mapping)
      return ChannelNotReadyError.new(problem) if problem

      Integrations::HttpAdapter.new(
        company_integration: mapping.company_integration,
        service: requirements(mapping).stock_template,
        payload: stock_payload(mapping),
        uri_params: { external_id: mapping.external_product_id }
      ).call
      nil
    rescue Integrations::AdapterExecutionError => e
      e
    end

    def not_ready_problem(mapping)
      requirements = requirements(mapping)
      requirements.setting_problem(mapping.company_integration.settings) ||
        requirements.refs_problem(mapping.external_refs)
    end

    # update_columns y no update!: es un registro del intento, no un cambio del
    # vínculo. No tiene que pasar por las validaciones (un vínculo viejo sin
    # referencias igual tiene que poder guardar por qué falla) ni mover
    # updated_at.
    def record(mapping, failure)
      error = failure && failure_detail(failure).truncate(MAX_ERROR_LENGTH)
      mapping.update_columns(last_synced_at: Time.current, last_sync_error: error) # rubocop:disable Rails/SkipsModelValidations
      failure
    end

    # Los identificadores extra del vínculo (en Shopify, `inventory_item_id`) van
    # en el payload para que el request_mapper los use. La clave de
    # idempotencia es por intento: fijar una cantidad absoluta es idempotente
    # por naturaleza, y hay canales que la exigen igual (Shopify, desde 2026-04).
    def stock_payload(mapping)
      mapping.external_refs.merge(
        'external_id' => mapping.external_product_id,
        Service::STOCK_KEY => total_stock,
        'idempotency_key' => SecureRandom.uuid
      )
    end

    # El total se calcula al ejecutar, no al encolar: si el stock volvió a
    # cambiar mientras el job esperaba en la cola, se publica el valor vigente.
    def total_stock
      @total_stock ||= @product.total_stock
    end

    # Si algún canal falló del lado del proveedor, se re-levanta como
    # AdapterExecutionError para que ApplicationJob lo reconozca como fallo
    # transitorio y reintente el job con espera creciente. Si todos los fallos
    # son de configuración, reintentar no sirve: ChannelNotReadyError.
    def raise_aggregated(failures)
      message = "outbound sync failed for #{failures.size} of #{mappings.size} channels: " \
                "#{failures.map { |failure| failure_detail(failure) }.join('; ')}"
      raise ChannelNotReadyError, message if failures.all?(ChannelNotReadyError)

      raise Integrations::AdapterExecutionError.new(
        message, payload: { product_id: @product.id, available_quantity: total_stock }
      )
    end

    # response_status es nil para fallos de red (timeout, conexión rechazada) y
    # para los de configuración; se agrega al mensaje sólo cuando la plataforma
    # respondió con un código.
    def failure_detail(failure)
      return failure.message unless failure.respond_to?(:response_status) && failure.response_status

      "#{failure.message} (status #{failure.response_status})"
    end
  end
end
