# frozen_string_literal: true

module Catalog
  # Empuja el stock consolidado de un producto a sus canales externos fuera del
  # ciclo del request. Va a la cola `low`: es tráfico saliente que puede esperar
  # y que no debe competir con los eventos entrantes de la cola `realtime`.
  #
  # Si el HttpAdapter falla, la excepción sube y ApplicationJob la reintenta con
  # espera creciente (sólo AdapterExecutionError; ver ADR-006).
  class SyncStockToChannelJob < ApplicationJob
    queue_as :low

    def perform(product_id, company_id)
      with_tenant(company_id) do
        # El producto puede haberse borrado entre el encolado y la ejecución:
        # sin producto no hay nada que propagar, porque sus mappings se fueron
        # con él. find_by y no find: es un final esperado, no un fallo del job.
        product = Product.find_by(id: product_id)
        return if product.nil?

        OutboundSync.new(product: product).call
      end
    end
  end
end
