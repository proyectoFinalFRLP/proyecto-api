# frozen_string_literal: true

module Api
  module V1
    class OrdersController < ApplicationController
      rescue_from ActiveRecord::RecordNotSaved, with: :render_unprocessable
      rescue_from Catalog::InsufficientStockError, with: :render_insufficient_stock
      # ParameterMissing no es 422 de negocio: es un 400 de contrato. Rescatarlo
      # acá mantiene la forma del body ({error: ...}) consistente con el resto
      # de la API en vez del default de Rails.
      rescue_from ActionController::ParameterMissing, with: :render_bad_request

      MAX_ITEMS = 100

      # Campos sobre los que corre el buscador del listado (TESIS-52). Son los
      # dos por los que un operador busca una venta: el nombre con el que la
      # cargó, o el id con el que la conoce el canal externo.
      SEARCH_FIELDS = %w[customer_name external_order_id].freeze

      def index
        page = [params[:page].to_i, 1].max
        per_page = params.fetch(:per_page, 20).to_i.clamp(1, 100)

        # La precarga alimenta dos columnas del serializer: `item_count` sale de
        # order_items y `carrier` de la cadena envío → integración → servicio.
        # Sin ella, cada fila de la página dispara sus propias consultas.
        orders = filtered_orders.preload(:order_items, shipment: { company_integration: :service })
                                .order(created_at: :desc, id: :desc)
                                .offset((page - 1) * per_page)
                                .limit(per_page)

        render json: {
          data: OrderListSerializer.render_as_hash(orders),
          # El total se cuenta sobre el scope YA FILTRADO, no sobre la tabla de
          # la empresa: de este número salen los KPIs de TESIS-53, que los pide
          # con `?status=pending&per_page=1` y lee sólo el meta. Si contara de
          # más, los KPIs mentirían.
          meta: { page: page, per_page: per_page, total: filtered_orders.count }
        }
      end

      def show
        # find y no find_by: Order es CompanyScoped, así que una orden de otra
        # empresa levanta RecordNotFound -> 404 y no confirma que exista.
        order = Order.includes(order_items: :product).find(params.expect(:id))
        authorize order

        render json: OrderSerializer.render(order)
      end

      def create
        authorize Order

        order = Orders::CreateOrder.new(
          params: order_params,
          items: items_params,
          company: current_company
        ).call

        render json: OrderSerializer.render(with_items(order)), status: :created
      end

      private

      # Blueprinter relee `order_items` de la base al serializar, así que los
      # productos que CreateOrder ya tenía en memoria no le sirven: sin esta
      # precarga, el alta haría una consulta por línea para el `product` del
      # OrderItemSerializer (hasta MAX_ITEMS por request).
      def with_items(order)
        Order.includes(order_items: :product).find(order.id)
      end

      # Un status desconocido no se rechaza: `where` lo busca igual y devuelve
      # la lista vacía, que es la respuesta honesta para un filtro que no
      # matchea nada. Mismo criterio que el listado de envíos.
      def filtered_orders
        orders = policy_scope(Order)
        orders = orders.where(status: params[:status]) if params[:status].present?
        apply_search(orders)
      end

      # ILIKE y no `LIKE`: el operador busca "perez" y espera encontrar "Pérez
      # S.A.". El término se escapa con `sanitize_sql_like` para que un `%` o un
      # `_` tipeados por el usuario se busquen literalmente en vez de comportarse
      # como comodines.
      def apply_search(orders)
        term = params[:search].to_s.strip
        return orders if term.blank?

        pattern = "%#{Order.sanitize_sql_like(term)}%"
        condition = SEARCH_FIELDS.map { |field| "#{field} ILIKE :pattern" }.join(' OR ')
        orders.where(condition, pattern: pattern)
      end

      def order_params
        order = params.require(:order)
        unless order.is_a?(ActionController::Parameters)
          raise ActiveRecord::RecordNotSaved, 'order must be an object'
        end

        order.permit(:customer_name, :customer_document,
                     :customer_address, :customer_zip_code)
      end

      def items_params
        raw = params[:order][:items]
        raise ActiveRecord::RecordNotSaved, 'items must be an array' unless raw.is_a?(Array)
        if raw.size > MAX_ITEMS
          raise ActiveRecord::RecordNotSaved,
                "items exceeds maximum of #{MAX_ITEMS}"
        end

        raw.map do |item|
          unless item.respond_to?(:permit)
            msg = 'each item must have product_id, quantity, unit_price and warehouse_id'
            raise ActiveRecord::RecordNotSaved, msg
          end

          item.permit(:product_id, :quantity, :unit_price, :warehouse_id).to_h.symbolize_keys
        end
      end

      def render_bad_request(exception)
        render json: { error: exception.message }, status: :bad_request
      end

      def render_unprocessable(exception)
        render json: { error: exception.message }, status: :unprocessable_content
      end

      def render_insufficient_stock(exception)
        render json: { error: exception.message }, status: :unprocessable_content
      end
    end
  end
end
