# frozen_string_literal: true

module Api
  module V1
    class WarehousesController < ApplicationController
      include Paginatable

      before_action :set_warehouse, only: %i[show update destroy]
      rescue_from ActiveRecord::RecordNotDestroyed, with: :render_conflict

      def index
        # with_stored_units agrega la suma de stocks en la misma consulta: sin
        # el scope, el serializer pediria las unidades deposito por deposito.
        #
        # `WHOLE_LIST_PER_PAGE` y no el default: el front usa este listado para
        # llenar selects —el picker de origen del alta manual, el de los modales
        # de producto—, no una tabla con paginador. Con 20 le faltarían depósitos
        # sin que nada se lo diga; el techo sigue existiendo y `meta.total` le
        # avisa si alguna vez lo pasa.
        #
        # `total:` explícito: with_stored_units agrupa por warehouses.id.
        scope = policy_scope(Warehouse).with_stored_units.order(created_at: :desc)
        warehouses, meta = paginate(scope, per_page: WHOLE_LIST_PER_PAGE,
                                           total: policy_scope(Warehouse).count)

        render json: { data: WarehouseSerializer.render_as_hash(warehouses), meta: meta }
      end

      def show
        render json: WarehouseSerializer.render(@warehouse)
      end

      def create
        authorize Warehouse

        # Defensa en profundidad: CompanyScoped#assign_current_company ya fuerza
        # el tenant en before_validation; el merge hace explícito de dónde sale.
        warehouse = Warehouse.create!(warehouse_params.merge(company: current_company))

        render json: WarehouseSerializer.render(warehouse), status: :created
      end

      def update
        @warehouse.update!(warehouse_params)

        render json: WarehouseSerializer.render(@warehouse), status: :ok
      end

      def destroy
        @warehouse.destroy!
        head :no_content
      end

      private

      def set_warehouse
        @warehouse = Warehouse.find(params.expect(:id))
        authorize @warehouse
      end

      # `expect` y no `require` + `permit`: si `warehouse` llega como String o
      # como Array, `require` lo devuelve igual y `permit` revienta con
      # NoMethodError, que salía como 500. `expect` responde 400.
      #
      # Un company_id en el body se sigue ignorando: `expect` descarta en
      # silencio las claves que no permite. (El comentario anterior decía que
      # respondía 400; en Rails 8.1 no es así, y el spec de company_id lo fija.)
      def warehouse_params
        params.expect(warehouse: %i[name zip_code address])
      end

      # Tres cosas bloquean el borrado y el mensaje tiene que decir cuál. Se
      # pregunta en el mismo orden en que el modelo las declara, que es el orden
      # en que `restrict_with_error` corta: si hay stock, el motivo es el stock.
      def render_conflict(_exception)
        render json: { error: "Cannot delete warehouse with #{blocking_reason}" },
               status: :conflict
      end

      def blocking_reason
        return 'existing stock' if @warehouse.stocks.exists?
        return 'order lines taken from it' if @warehouse.order_items.exists?

        'stock transfers from or to it'
      end
    end
  end
end
