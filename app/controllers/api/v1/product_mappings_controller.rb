# frozen_string_literal: true

module Api
  module V1
    class ProductMappingsController < ApplicationController
      MISSING_INTEGRATION = 'company_integration_id is required'
      ALREADY_LINKED = 'external product already linked to another product in this integration'

      before_action :set_product

      rescue_from ActiveRecord::RecordNotSaved, with: :render_unprocessable
      rescue_from ActiveRecord::RecordNotUnique, with: :render_conflict

      def index
        mappings = policy_scope(ProductMapping)
                   .where(product_id: @product.id)
                   .includes(company_integration: :service)
                   .order(:created_at)

        # Se envuelve en `data` para que el front trate una sola shape en todo
        # el árbol de /products. No lleva `meta` como el index de productos:
        # los mappings son tantos como canales de venta y no se paginan.
        render json: { data: ProductMappingSerializer.render_as_hash(mappings) }
      end

      def create
        authorize ProductMapping

        mapping = @product.product_mappings.create!(
          company_integration: company_integration,
          external_product_id: mapping_params[:external_product_id],
          external_price: mapping_params[:external_price]
        )

        render json: ProductMappingSerializer.render(mapping), status: :created
      end

      def destroy
        # Buscar el mapping a través del producto (ya validado como propio) evita
        # que un mapping_id de otro producto o de otra empresa sea alcanzable.
        mapping = @product.product_mappings.find(params.expect(:id))
        authorize mapping
        mapping.destroy!
        head :no_content
      end

      private

      # El producto viene de la URL y Product.find aplica el default_scope de
      # CompanyScoped: un product_id de otra empresa devuelve 404 y la request
      # nunca llega a tocar el mapping.
      def set_product
        @product = Product.find(params.expect(:product_id))
        # index sólo lee; create y destroy agregan o quitan un vínculo del
        # producto, así que se autorizan como una modificación de éste.
        authorize @product, action_name == 'index' ? :show? : :update?
      end

      # La integración viene del body: es el vector de ataque que menciona la
      # card (vincular un producto propio a la cuenta de otra PyME).
      # CompanyIntegration.find también está scopeada por tenant, así que una
      # integración ajena devuelve 404 en vez de crear el vínculo.
      def company_integration
        integration_id = mapping_params[:company_integration_id]
        raise ActiveRecord::RecordNotSaved, MISSING_INTEGRATION if integration_id.blank?

        CompanyIntegration.find(integration_id)
      end

      # El body va anidado bajo `product_mapping`, igual que `product` en
      # ProductsController: los dos endpoints del mismo árbol comparten contrato.
      def mapping_params
        # rubocop:disable-next Rails/StrongParametersExpect
        params.require(:product_mapping)
              .permit(:company_integration_id, :external_product_id, :external_price)
      end

      # El índice único (company_integration_id, external_product_id) no tiene
      # validación de modelo a propósito: la unicidad la resuelve la DB sin
      # condición de carrera y acá se traduce a 409.
      def render_conflict(_exception)
        render json: { error: ALREADY_LINKED }, status: :conflict
      end
    end
  end
end
