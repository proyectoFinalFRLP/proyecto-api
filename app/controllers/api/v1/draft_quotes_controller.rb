# frozen_string_literal: true

module Api
  module V1
    # Cotización de un alta que todavía no se confirmó (TESIS-131).
    #
    # La cotización de TESIS-46 cuelga de una orden, y crear la orden descuenta
    # el stock. El paso 3 del alta manual (TESIS-59) necesita mostrar las tarifas
    # ANTES de que el operador confirme, así que acá se cotiza el paquete con lo
    # que el asistente ya juntó: depósito de origen, destino y líneas. La orden se
    # crea una sola vez, cuando el operador elige y confirma.
    class DraftQuotesController < ApplicationController
      # El parámetro que falta es un 400 de contrato, con el mismo cuerpo
      # `{ error }` que el resto de la API.
      rescue_from ActionController::ParameterMissing, with: :render_bad_request

      def create
        # Cotizar un borrador es el paso previo a darlo de alta: se autoriza como
        # crear una orden. Cada request va a los couriers con las credenciales de
        # la empresa, pero no lee ni toca nada que no sea del propio tenant.
        authorize Order, :create?

        quotes = Shipments::QuoteShipment.new(
          origin_warehouse: origin_warehouse, destination: destination, lines: lines
        ).call

        # 200 y una lista vacía cuando nadie contestó, igual que la cotización de
        # una orden: el front distingue «sin opciones» de «falló la cotización».
        render json: { data: quotes }, status: :ok
      end

      private

      def quote_params
        params.expect(quote: [:origin_warehouse_id, :destination_zip_code, :destination_address,
                              { items: [%i[product_id quantity]] }])
      end

      # find y no find_by: Warehouse es CompanyScoped, así que un id de otra
      # empresa levanta RecordNotFound -> 404 en vez de revelar que existe.
      def origin_warehouse
        Warehouse.find(required(:origin_warehouse_id))
      end

      # El código postal es lo que cotizan todas las plantillas: sin él no hay
      # tarifa posible. La dirección viaja si está, porque algunas la piden.
      def destination
        { zip_code: required(:destination_zip_code).to_s.strip,
          address: quote_params[:destination_address].to_s.strip.presence }
      end

      # Pares [producto, cantidad]. Los productos se buscan dentro del tenant: uno
      # ajeno no aparece y responde 404, como el resto de la API.
      def lines
        products = Product.where(id: items.map(&:first)).index_by(&:id)
        items.map do |product_id, quantity|
          [products.fetch(product_id) { raise ActiveRecord::RecordNotFound }, quantity]
        end
      end

      # El mismo tope que el alta (OrdersController::MAX_ITEMS): cotizar algo que
      # después no se podría crear no le sirve a nadie.
      def items
        @items ||= begin
          raw = quote_params[:items]
          raise ActionController::ParameterMissing, :items if raw.blank?

          limit = OrdersController::MAX_ITEMS
          raise MalformedParameterError, "items exceeds maximum of #{limit}" if raw.size > limit

          raw.map do |item|
            [positive_integer(item, :product_id), positive_integer(item, :quantity)]
          end
        end
      end

      # «Bien formado» acá es un entero positivo. Un 0, un negativo o un texto
      # no son un producto ni una cantidad que se pueda enviar.
      def positive_integer(item, key)
        value = Integer(item[key].to_s, exception: false)
        return value if value&.positive?

        raise MalformedParameterError, "each item needs a positive integer #{key}"
      end

      # `expect` cubre la clave ausente, no el valor vacío: sin esto un id en
      # blanco llegaba a `find('')` y salía como 404, diciéndole al cliente que el
      # recurso no existe cuando lo que falta es el parámetro.
      def required(name)
        value = quote_params[name]
        raise ActionController::ParameterMissing, name if value.blank?

        value
      end
    end
  end
end
