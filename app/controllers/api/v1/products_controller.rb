# frozen_string_literal: true

module Api
  module V1
    class ProductsController < ApplicationController
      before_action :set_product, only: %i[show update destroy]
      rescue_from ActiveRecord::RecordInvalid, with: :render_unprocessable
      rescue_from ActiveRecord::RecordNotUnique, with: :render_conflict
      rescue_from ActiveRecord::RecordNotSaved, with: :render_unprocessable

      def index
        page = [params[:page].to_i, 1].max
        per_page = params.fetch(:per_page, 20).to_i.clamp(1, 100)

        products = policy_scope(Product).with_total_stock
                                        .order(created_at: :desc)
                                        .offset((page - 1) * per_page)
                                        .limit(per_page)

        render json: ProductListSerializer.render(products)
      end

      def show
        render json: ProductSerializer.render(@product)
      end

      def create
        authorize Product

        product = Products::CreateProduct.new(
          params: product_params,
          stocks: stock_params,
          company: current_company
        ).call

        render json: ProductSerializer.render(product), status: :created
      end

      def update
        product = Products::UpdateProduct.new(
          product: @product,
          params: product_params,
          stocks: stock_params,
          company: current_company
        ).call

        render json: ProductSerializer.render(product), status: :ok
      end

      def destroy
        @product.destroy!
        head :no_content
      end

      private

      def set_product
        @product = Product.find(params.expect(:id))
        authorize @product
      end

      def product_params
        # rubocop:disable Rails/StrongParametersExpect
        params.require(:product).permit(:sku, :name, :description, :weight, :dimensions)
        # rubocop:enable Rails/StrongParametersExpect
      end

      def stock_params
        raw_stocks = params[:product][:stocks]
        return [] if raw_stocks.nil?

        # Si stocks viene presente pero no es un array (ej. un objeto), es un
        # payload inválido: rechazarlo con 422 en vez de descartarlo en silencio.
        unless raw_stocks.is_a?(Array)
          raise ActiveRecord::RecordNotSaved, 'stocks must be an array'
        end

        raw_stocks.map do |s|
          # Cada elemento debe ser un objeto con warehouse_id/quantity.
          unless s.respond_to?(:permit)
            raise ActiveRecord::RecordNotSaved,
                  'each stock must be an object with warehouse_id and quantity'
          end

          s.permit(:warehouse_id, :quantity).to_h.symbolize_keys
        end
      end

      def current_company
        current_user.company
      end

      def render_unprocessable(exception)
        render json: { error: exception.message }, status: :unprocessable_content
      end

      def render_conflict(_exception)
        render json: { error: 'SKU already exists' }, status: :conflict
      end
    end
  end
end
