# frozen_string_literal: true

module Api
  module V1
    # Cotización logística de una orden (TESIS-46).
    class ShippingQuotesController < ApplicationController
      def create
        order = Order.find(params.expect(:order_id))
        authorize order, :quote?

        quotes = Shipping::QuoteShipping.new(
          order: order, origin_warehouse: origin_warehouse
        ).call

        # 200 y no 201: no se creó nada. Una lista vacía es una respuesta válida
        # —ningún operador contestó a tiempo— y no un error: el front muestra
        # "sin opciones disponibles", que es distinto de "falló la cotización".
        render json: { data: quotes }, status: :ok
      end

      private

      # El depósito de origen viaja en el request y no se deduce de la orden.
      # `shipments` no guarda origen, y los ítems de una orden pueden estar en
      # varios depósitos: cualquier regla automática sería una invención. Además
      # el propio diseño ya tiene al usuario eligiéndolo — TESIS-58, "Wizard
      # Orden Manual (Paso 2): Origen y Destino".
      #
      # find y no find_by: Warehouse es CompanyScoped, así que un id de otra
      # empresa levanta RecordNotFound -> 404 en vez de revelar que existe.
      def origin_warehouse
        Warehouse.find(quote_params[:origin_warehouse_id])
      end

      def quote_params
        params.expect(quote: [:origin_warehouse_id])
      end
    end
  end
end
