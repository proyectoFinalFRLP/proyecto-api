# frozen_string_literal: true

module Api
  module V1
    # Lista, detalle, alta y despacho de envíos. El alta (TESIS-105) cuelga de la
    # orden —POST /api/v1/orders/:order_id/shipment— porque un envío nace siempre
    # de una: es el punto de entrada de la épica logística. Después de eso lo
    # único que el usuario decide es con qué operador despacharlo (TESIS-47); el
    # resto del avance lo escribe el push de tracking del courier (TESIS-48).
    class ShipmentsController < ApplicationController
      before_action :set_shipment, only: %i[show]

      rescue_from Shipments::UnshippableOrderError, with: :render_unprocessable
      rescue_from Shipments::DuplicateShipmentError, with: :render_conflict
      rescue_from Shipments::AlreadyDispatchedError, with: :render_conflict
      rescue_from Shipments::InvalidCourierIntegrationError, with: :render_unprocessable
      rescue_from Shipments::DispatchResponseError, with: :render_bad_gateway
      rescue_from Integrations::AdapterExecutionError, with: :render_courier_failure
      # El parámetro que falta es un 400 de contrato, no un 422 de negocio.
      rescue_from ActionController::ParameterMissing, with: :render_bad_request

      # Cuánto del cuerpo del courier se propaga en el mensaje de error.
      COURIER_ERROR_LIMIT = 300

      def index
        page = [params[:page].to_i, 1].max
        per_page = params.fetch(:per_page, 20).to_i.clamp(1, 100)

        # La precarga es load-bearing: ShipmentListSerializer lee el nombre del
        # courier a través de la plantilla del Service, y sin ella son dos
        # queries por fila (company_integrations + services).
        shipments = filtered_shipments.preload(company_integration: :service)
                                      .order(created_at: :desc, id: :desc)
                                      .offset((page - 1) * per_page)
                                      .limit(per_page)

        render json: {
          data: ShipmentListSerializer.render_as_hash(shipments),
          # El total se cuenta sobre el scope filtrado, no sobre el total de la
          # empresa: de acá sale el KPI de envíos activos (TESIS-53).
          meta: { page: page, per_page: per_page, total: filtered_shipments.count }
        }
      end

      def show
        render json: ShipmentSerializer.render(@shipment)
      end

      def create
        # find y no find_by: Order es CompanyScoped, así que una orden de otra
        # empresa levanta RecordNotFound -> 404 y no confirma que exista.
        order = Order.find(params.expect(:order_id))
        # Se autoriza la orden y no el envío, igual que la cotización de
        # TESIS-46: el envío todavía no existe cuando corre el chequeo, y el
        # permiso es sobre la orden. ShipmentPolicy sigue siendo de sólo lectura.
        authorize order, :ship?

        shipment = Shipments::CreateShipment.new(order: order).call

        render json: ShipmentSerializer.render(shipment), status: :created
      end

      # Confirma el despacho con el operador que el usuario eligió al cotizar
      # (TESIS-47). Se llama `confirm` y no `dispatch` porque `dispatch` ya es un
      # método de instancia de ActionController::Metal —el que corre cada acción—
      # y pisarlo rompe el controller entero. La ruta sí es `/dispatch`, que es la
      # que pide la card.
      def confirm
        shipment = Shipment.find(params.expect(:id))
        authorize shipment, :dispatch?

        dispatched = Shipments::ConfirmDispatch.new(
          shipment: shipment, company_integration: courier_integration,
          origin_warehouse: origin_warehouse, shipping_cost: shipping_cost
        ).call

        render json: ShipmentSerializer.render(dispatched), status: :ok
      end

      private

      # Un status desconocido no se filtra ni se rechaza: `where` lo busca igual
      # y devuelve la lista vacía, que es la respuesta honesta para un filtro que
      # no matchea nada (status es un string plano, no un enum: no rompe).
      def filtered_shipments
        shipments = policy_scope(Shipment)
        shipments = shipments.where(status: params[:status]) if params[:status].present?
        shipments = shipments.where(order_id: params[:order_id]) if params[:order_id].present?
        shipments
      end

      # find y no find_by dentro del scope del tenant: el default_scope de
      # CompanyScoped ya acota, así que un id de otra empresa levanta
      # RecordNotFound -> 404, que es lo que corresponde (no revelar que existe).
      def set_shipment
        @shipment = Shipment.includes(:shipment_events, company_integration: :service)
                            .find(params.expect(:id))
        authorize @shipment
      end

      # find y no find_by: las dos son CompanyScoped, así que un id de otra
      # empresa levanta RecordNotFound -> 404 en vez de revelar que existe.
      def courier_integration
        CompanyIntegration.includes(:service).find(required_param(:company_integration_id))
      end

      # El depósito de origen viaja en el request por el mismo motivo que en la
      # cotización (TESIS-46): `shipments` no guarda origen y los ítems de una
      # orden pueden estar en varios depósitos, así que deducirlo sería inventarlo.
      def origin_warehouse
        Warehouse.find(required_param(:origin_warehouse_id))
      end

      def dispatch_params
        params.expect(dispatch: %i[company_integration_id origin_warehouse_id shipping_cost])
      end

      # El costo de la opción que el operador confirmó al cotizar (TESIS-131). Se
      # valida acá, antes de llamar al courier, para no gastar una etiqueta en un
      # despacho que después no se podría guardar. Opcional: sin él, el despacho
      # funciona como antes.
      def shipping_cost
        raw = dispatch_params[:shipping_cost]
        return nil if raw.blank?

        cost = BigDecimal(raw.to_s, exception: false)
        return cost if cost && !cost.negative?

        raise MalformedParameterError, 'shipping_cost must be a number, zero or greater'
      end

      # `expect` cubre la clave ausente, no el valor vacío: sin esto un id en
      # blanco llegaba a `find('')` y salía como 404, diciéndole al cliente que el
      # recurso no existe cuando lo que falta es el parámetro.
      def required_param(name)
        value = dispatch_params[name]
        raise ActionController::ParameterMissing, name if value.blank?

        value
      end

      # 409 y no 422: la orden ya tiene su envío —o el envío ya se despachó—, y no
      # hay nada que el cliente pueda corregir en el body para que el mismo
      # request funcione.
      def render_conflict(exception)
        render json: { error: exception.message }, status: :conflict
      end

      # El courier contestó algo inesperado (o no contestó): el fallo es aguas
      # arriba, no del request. 502 lo dice; un 500 diría que el que se rompió
      # fue este sistema.
      def render_bad_gateway(exception)
        render json: { error: exception.message }, status: :bad_gateway
      end

      # Un rechazo del courier se separa en dos: si contestó 4xx, el problema
      # está en los datos del envío —un código postal que no cubre, por ejemplo—
      # y el usuario puede corregirlo, así que es 422. Un 5xx, un timeout o una
      # respuesta ilegible no son corregibles desde acá: son 502. En los dos casos
      # viaja el mensaje original, que es lo que la card pide propagar.
      def render_courier_failure(exception)
        status = exception.response_status.to_i
        upstream_rejected = status.between?(400, 499)

        render json: { error: courier_message(exception) },
               status: upstream_rejected ? :unprocessable_content : :bad_gateway
      end

      # "Andreani responded with HTTP 422" no le dice a nadie qué corregir: lo
      # accionable —el código postal fuera de cobertura, el bulto sin peso— viene
      # en el cuerpo de la respuesta del courier, y la card pide propagarlo.
      def courier_message(exception)
        detail = courier_detail(exception.response_body)
        return exception.message if detail.blank?

        "#{exception.message}: #{detail}"
      end

      # El cuerpo es de un tercero: puede ser JSON con el motivo, JSON con otra
      # forma, o HTML de un proxy. Se recorta para no devolver una página entera
      # como mensaje de error.
      def courier_detail(body)
        parsed = JSON.parse(body.to_s)
        detail = parsed.values_at('error', 'message', 'detail').compact.first if parsed.is_a?(Hash)

        (detail || parsed).to_s.truncate(COURIER_ERROR_LIMIT)
      rescue JSON::ParserError
        body.to_s.truncate(COURIER_ERROR_LIMIT)
      end
    end
  end
end
