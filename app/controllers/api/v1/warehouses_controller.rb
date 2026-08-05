# frozen_string_literal: true

module Api
  module V1
    class WarehousesController < ApplicationController
      before_action :set_warehouse, only: %i[show update destroy]
      rescue_from ActiveRecord::RecordNotDestroyed, with: :render_conflict
      rescue_from ActiveRecord::RecordInvalid, with: :render_unprocessable

      def index
        warehouses = policy_scope(Warehouse).order(created_at: :desc)

        render json: WarehouseSerializer.render(warehouses)
      end

      def show
        render json: WarehouseSerializer.render(@warehouse)
      end

      def create
        authorize Warehouse

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
        # rubocop:disable Rails/StrongParametersExpect
        params.require(:warehouse).permit(:name, :zip_code, :address)
        # rubocop:enable Rails/StrongParametersExpect
      end

      def current_company
        current_user.company
      end

      def render_unprocessable(exception)
        render json: { error: exception.message }, status: :unprocessable_content
      end

      def render_conflict(_exception)
        render json: { error: 'Cannot delete warehouse with existing stock' },
               status: :conflict
      end
    end
  end
end
