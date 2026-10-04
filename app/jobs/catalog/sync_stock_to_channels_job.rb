# frozen_string_literal: true

module Catalog
  # Empuja el stock consolidado de un producto a sus canales externos fuera del
  # ciclo del request. Va a la cola `low`: es tráfico saliente que puede esperar
  # y que no debe competir con los eventos entrantes de la cola `realtime`.
  #
  # Si el HttpAdapter falla, la excepción sube y ApplicationJob la reintenta con
  # espera creciente (sólo AdapterExecutionError; ver ADR-006).
  class SyncStockToChannelsJob < ApplicationJob
    queue_as :low

    # `company_integration_id` acota el push a un canal (ver OutboundSync): sin
    # él se publica en todos, que es lo que pide un cambio de stock.
    def perform(product_id, company_id, company_integration_id = nil)
      with_tenant(company_id) do
        # El producto puede haberse borrado entre el encolado y la ejecución:
        # sin producto no hay nada que propagar, porque sus mappings se fueron
        # con él. find_by y no find: es un final esperado, no un fallo del job.
        product = Product.find_by(id: product_id)
        return if product.nil?

        # La integración pudo borrarse mientras el job esperaba: sin canal no hay
        # nada que alinear.
        if company_integration_id
          integration = CompanyIntegration.find_by(id: company_integration_id)
          return if integration.nil?
        end

        OutboundSync.new(product: product, company_integration: integration).call
      end
    end
  end
end
