# frozen_string_literal: true

module Api
  module V1
    # El body de `POST /api/v1/shipments/:id/dispatch` (TESIS-47): con qué
    # courier, desde qué depósito, a qué costo y en cuántos días. Vive aparte
    # del controller de envíos porque es una sola cosa —leer y validar ese
    # body— y el controller ya junta el listado, el detalle, el alta, el
    # despacho y la etiqueta.
    module DispatchParams
      extend ActiveSupport::Concern

      # Tope de los días estimados que acepta el despacho (ver `estimated_days`).
      # Los errores de forma son los de ApplicationController, con su nombre
      # completo: un módulo no ve las constantes de la clase que lo incluye.
      MAX_ESTIMATED_DAYS = 365

      private

      # find y no find_by: las dos son CompanyScoped, así que un id de otra
      # empresa levanta RecordNotFound -> 404 en vez de revelar que existe.
      def courier_integration
        CompanyIntegration.includes(:service).find(required_param(:company_integration_id))
      end

      # El depósito de origen viaja en el request por el mismo motivo que en la
      # cotización (TESIS-46): los ítems de una orden pueden estar en varios
      # depósitos, así que deducirlo sería inventarlo. El despacho lo guarda en
      # el envío, para el detalle de la orden y las anomalías de Reportes.
      def origin_warehouse
        Warehouse.find(required_param(:origin_warehouse_id))
      end

      def dispatch_params
        params.expect(dispatch: %i[company_integration_id origin_warehouse_id shipping_cost
                                   estimated_days])
      end

      # Los días de entrega de la opción que el operador confirmó al cotizar. De
      # ellos sale la fecha comprometida del envío. Opcional, como el costo: hay
      # couriers que cotizan sin plazo, y un despacho sin días queda sin fecha
      # comprometida en vez de con una inventada.
      #
      # El techo no es un plazo real: es para que un número absurdo sea un 400 y
      # no una fecha en el año 30.000 que después nadie entiende.
      def estimated_days
        raw = dispatch_params[:estimated_days]
        return nil if raw.blank?

        days = Integer(raw.to_s, 10, exception: false)
        return days if days&.between?(0, MAX_ESTIMATED_DAYS)

        raise ApplicationController::MalformedParameterError,
              "estimated_days must be a whole number between 0 and #{MAX_ESTIMATED_DAYS}"
      end

      # El costo de la opción que el operador confirmó al cotizar (TESIS-131).
      # Opcional: sin él, el despacho funciona como antes. Acá sólo se lee como
      # número; el rango lo valida ConfirmDispatch contra el modelo, antes de
      # llamar al courier, para que la regla viva en un solo lugar.
      def shipping_cost
        raw = dispatch_params[:shipping_cost]
        return nil if raw.blank?

        BigDecimal(raw.to_s, exception: false) ||
          raise(ApplicationController::MalformedParameterError, 'shipping_cost must be a number')
      end

      # `expect` cubre la clave ausente, no el valor vacío: sin esto un id en
      # blanco llegaba a `find('')` y salía como 404, diciéndole al cliente que el
      # recurso no existe cuando lo que falta es el parámetro.
      def required_param(name)
        value = dispatch_params[name]
        raise ActionController::ParameterMissing, name if value.blank?

        value
      end
    end
  end
end
