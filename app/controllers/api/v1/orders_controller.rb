# frozen_string_literal: true

module Api
  module V1
    class OrdersController < ApplicationController
      rescue_from ActiveRecord::RecordNotSaved, with: :render_unprocessable
      rescue_from ActiveRecord::RecordNotFound, with: :render_unprocessable
      rescue_from Catalog::InsufficientStockError, with: :render_insufficient_stock

      MAX_ITEMS = 100

      def create
        authorize Order

        order = Orders::CreateOrder.new(
          params: order_params,
          items: items_params,
          company: current_company
        ).call

        render json: OrderSerializer.render(order), status: :created
      end

      private

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

      def render_unprocessable(exception)
        render json: { error: exception.message }, status: :unprocessable_content
      end

      def render_insufficient_stock(exception)
        render json: { error: exception.message }, status: :unprocessable_content
      end
    end
  end
end
