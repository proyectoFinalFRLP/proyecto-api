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

      # Campos sobre los que corre el buscador del listado (TESIS-52). Son las
      # formas en que un operador nombra una venta: el id con el que la conoce el
      # canal externo, el nombre con el que la cargó, y a dónde va.
      #
      # El destino entra con sus DOS columnas. La pantalla ofrece buscar «por ID
      # o destino» y muestra la dirección con el código postal debajo, como una
      # sola celda; buscar sólo por la dirección dejaba afuera al operador que
      # tipea «1406», que es la mitad de lo que está viendo.
      SEARCH_FIELDS = %w[
        customer_name external_order_id customer_address customer_zip_code
      ].freeze

      def index
        # `scalar_param` y no `params[...]` directo: una query con `?page[]=1`
        # entrega un Array y `to_i` sale con NoMethodError → 500. Ver
        # ApplicationController.
        page = [scalar_param(:page).to_i, 1].max
        per_page = (scalar_param(:per_page) || 20).to_i.clamp(1, 100)

        # La precarga alimenta dos columnas del serializer: `item_count` sale de
        # order_items y `courier` de la cadena envío → integración → servicio.
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
      #
      # Desconocido no es lo mismo que mal formado: `?status[foo]=bar` llega
      # como ActionController::Parameters y ActiveRecord lo rechaza con
      # TypeError. `scalar_param` lo corta antes, con un 400.
      #
      # Memoizado porque `index` lo pide dos veces —una para la página y otra
      # para `meta.total`— y cada llamada rearmaba el scope desde cero, incluida
      # la condición de búsqueda. Las dos consultas a la base siguen siendo dos:
      # paginar exige contar aparte. Lo que se evita es construirlo de nuevo.
      def filtered_orders
        @filtered_orders ||= begin
          status = scalar_param(:status)
          orders = policy_scope(Order)
          orders = orders.where(status: status) if status.present?
          apply_search(orders)
        end
      end

      # ILIKE y no `LIKE`: el operador busca "perez" y encuentra "PEREZ S.A.".
      #
      # Ignora mayúsculas, NO ignora acentos: "perez" no encuentra "Pérez S.A.",
      # porque en Postgres `é` y `e` son caracteres distintos y ILIKE sólo aplica
      # el plegado de caja. Resolverlo pide la extensión `unaccent`, y hacerlo
      # acá solo dejaría el buscador de productos —que tiene el mismo ILIKE— con
      # otro comportamiento. Va como card aparte.
      #
      # Sin índice, igual que el buscador del catálogo: un `%term%` no puede usar
      # un B-tree y necesita un índice GIN con `pg_trgm`. Es la misma extensión y
      # la misma decisión que unaccent, así que viaja en la misma card en vez de
      # quedar a medias en este PR.
      #
      # El término se escapa con `sanitize_sql_like` para que un `%` o un `_`
      # tipeados por el usuario se busquen literalmente en vez de comportarse
      # como comodines.
      def apply_search(orders)
        term = scalar_param(:search).to_s.strip
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
                     :customer_address, :customer_zip_code,
                     :customer_city, :customer_province)
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

      def render_unprocessable(exception)
        render json: { error: exception.message }, status: :unprocessable_content
      end

      def render_insufficient_stock(exception)
        render json: { error: exception.message }, status: :unprocessable_content
      end
    end
  end
end
