# frozen_string_literal: true

module Api
  module V1
    class StockTransfersController < ApplicationController
      before_action :set_transfer, only: %i[receive cancel]
      rescue_from Catalog::InsufficientWarehouseStockError, with: :render_unprocessable
      rescue_from Catalog::SettleTransfer::NotInFlightError, with: :render_conflict

      def index
        transfers = policy_scope(StockTransfer)
                    .includes(:product, :origin_warehouse, :destination_warehouse)
                    .order(dispatched_at: :desc)
        transfers = transfers.where(status: params[:status]) if params[:status].present?
        transfers = transfers.where(product_id: params[:product_id]) if params[:product_id].present?

        render json: { data: StockTransferSerializer.render_as_hash(transfers) }
      end

      def create
        authorize StockTransfer

        transfer = Catalog::DispatchTransfer.new(
          company: current_company, product: product_for_create,
          origin_warehouse: warehouse_for(:origin_warehouse_id),
          destination_warehouse: warehouse_for(:destination_warehouse_id),
          quantity: transfer_params[:quantity]
        ).call

        render json: StockTransferSerializer.render(transfer), status: :created
      end

      def receive
        settle(:received)
      end

      def cancel
        settle(:cancelled)
      end

      private

      def settle(outcome)
        transfer = Catalog::SettleTransfer.new(transfer: @transfer, outcome: outcome).call

        render json: StockTransferSerializer.render(transfer), status: :ok
      end

      def set_transfer
        @transfer = StockTransfer.find(params.expect(:id))
        authorize @transfer, :"#{action_name}?"
      end

      # find y no find_by en el scope del tenant: el default_scope de
      # CompanyScoped ya acota, así que un id de otra empresa levanta
      # RecordNotFound -> 404, que es lo que corresponde (no revelar que existe).
      def product_for_create
        Product.find(transfer_params[:product_id])
      end

      def warehouse_for(key)
        Warehouse.find(transfer_params[key])
      end

      def transfer_params
        # permit y no expect, igual que en productos: un body con company_id se
        # ignora en lugar de devolver 400.
        # rubocop:disable Rails/StrongParametersExpect
        params.require(:stock_transfer)
              .permit(:product_id, :origin_warehouse_id, :destination_warehouse_id, :quantity)
        # rubocop:enable Rails/StrongParametersExpect
      end

      def render_conflict(exception)
        render json: { error: exception.message }, status: :conflict
      end
    end
  end
end
