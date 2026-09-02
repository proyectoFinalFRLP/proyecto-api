# frozen_string_literal: true

module Api
  module V1
    class WarehousesController < ApplicationController
      before_action :set_warehouse, only: %i[show update destroy]
      rescue_from ActiveRecord::RecordNotDestroyed, with: :render_conflict

      def index
        warehouses = policy_scope(Warehouse).order(created_at: :desc)

        render json: { data: WarehouseSerializer.render_as_hash(warehouses) }
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

      def warehouse_params
        # permit (no expect) es intencional y load-bearing: expect usa
        # on_unpermitted: :raise, así que un body con company_id daría 400 en
        # vez de ignorarlo — rompiendo el requisito de la card.
        # rubocop:disable-next Rails/StrongParametersExpect
        params.require(:warehouse).permit(:name, :zip_code, :address)
      end

      def render_conflict(_exception)
        render json: { error: 'Cannot delete warehouse with existing stock' },
               status: :conflict
      end
    end
  end
end
