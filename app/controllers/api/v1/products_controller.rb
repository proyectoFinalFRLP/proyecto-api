# frozen_string_literal: true

module Api
  module V1
    class ProductsController < ApplicationController
      before_action :set_product, only: %i[show update destroy]
      rescue_from ActiveRecord::RecordNotUnique, with: :render_conflict
      rescue_from ActiveRecord::RecordNotSaved, with: :render_unprocessable
      rescue_from Catalog::StaleProductError, with: :render_precondition_failed

      def index
        page = [params[:page].to_i, 1].max
        per_page = params.fetch(:per_page, 20).to_i.clamp(1, 100)

        products = policy_scope(Product).with_total_stock
                                        .order(created_at: :desc)
                                        .offset((page - 1) * per_page)
                                        .limit(per_page)

        # total se cuenta sobre el scope sin with_total_stock: al estar agrupado,
        # .count sobre el scope con with_total_stock devolvería un Hash, no entero.
        total = policy_scope(Product).count

        render json: {
          data: ProductListSerializer.render_as_hash(products),
          meta: { page: page, per_page: per_page, total: total }
        }
      end

      def show
        expose_version(@product)
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
          expected_version: expected_version
        ).call

        expose_version(product)
        render json: ProductSerializer.render(product), status: :ok
      end

      def destroy
        @product.destroy!
        head :no_content
      end

      private

      # La version del agregado viaja como ETag (TESIS-101). El cliente la
      # devuelve en `If-Match` al guardar y el servidor rechaza la escritura si
      # ya no es la vigente.
      def expose_version(product)
        response.set_header('ETag', %("#{Catalog::ProductVersion.new(product: product).call}"))
      end

      # `If-Match` puede venir con comillas, con el prefijo debil `W/` o como
      # `*`. `*` significa "cualquier version, siempre que exista": el producto
      # ya se resolvio en set_product, asi que equivale a no poner precondicion.
      def expected_version
        raw = request.headers['If-Match'].to_s.strip
        return nil if raw.blank? || raw == '*'

        raw.delete_prefix('W/').delete_prefix('"').delete_suffix('"')
      end

      # 412 y no 409, apartandose de lo que pedia la card. Es el codigo que HTTP
      # define para una precondicion que no se cumple, y de paso resuelve solo el
      # requisito de distinguirlo: este endpoint ya devuelve 409 por SKU
      # duplicado y por lock de stock ocupado, y un tercer 409 obligaria al front
      # a leer el cuerpo para saber cual es. Con 412 alcanza el status.
      def render_precondition_failed(exception)
        render json: { error: exception.message, current_version: exception.current_version },
               status: :precondition_failed
      end

      def set_product
        # Eager load de stocks y sus warehouses para evitar N+1 en el detalle.
        @product = Product.includes(stocks: :warehouse).find(params.expect(:id))
        authorize @product
      end

      def product_params
        # permit (no expect) es intencional y load-bearing: expect usa
        # on_unpermitted: :raise, así que un body con company_id daría 400 en
        # vez de ignorarlo — rompiendo el requisito de la card.
        # rubocop:disable Rails/StrongParametersExpect
        params.require(:product).permit(:sku, :name, :description, :weight, :dimensions)
        # rubocop:enable Rails/StrongParametersExpect
      end

      def stock_params
        raw_stocks = params[:product][:stocks]
        return [] if raw_stocks.nil?

        # Si stocks viene presente pero no es un array (ej. un objeto), es un
        # payload inválido: rechazarlo con 422 en vez de descartarlo en silencio.
        raise ActiveRecord::RecordNotSaved, 'stocks must be an array' unless raw_stocks.is_a?(Array)

        raw_stocks.map do |s|
          # Cada elemento debe ser un objeto con warehouse_id/quantity.
          unless s.respond_to?(:permit)
            raise ActiveRecord::RecordNotSaved,
                  'each stock must be an object with warehouse_id and quantity'
          end

          s.permit(:warehouse_id, :quantity).to_h.symbolize_keys
        end
      end

      # RecordNotUnique llega por dos índices distintos y el mensaje tiene que
      # decir cuál: el de sku por company, y el de stocks por producto +
      # depósito (dos escrituras que crean la misma fila de stock a la vez).
      # Responder siempre 'SKU already exists' mandaba al front a buscar un
      # duplicado de SKU que no existía.
      def render_conflict(exception)
        message = if exception.message.include?('index_stocks_on_product_id_and_warehouse_id')
                    'stock for this warehouse is being written by another operation, please retry'
                  else
                    'SKU already exists'
                  end

        render json: { error: message }, status: :conflict
      end
    end
  end
end
