# frozen_string_literal: true

module Catalog
  # Vincula un producto con su publicación en un canal de venta
  # (ProductMapping) y deja el stock del canal alineado con el del OMS.
  #
  # Si el proveedor sabe buscar la publicación, se le pregunta antes de crear el
  # vínculo, con plantillas hijas de la integración (nunca código por proveedor):
  # - con un id externo, la hija `product_lookup` confirma que existe y trae los
  #   identificadores extra que necesita el canal para publicar el stock
  #   (en Shopify, el `inventory_item_id` de la variante);
  # - sin id externo, la hija `product_search` la busca por el SKU del producto.
  #   Sólo se acepta un resultado único con el mismo SKU: vincular el producto
  #   equivocado le publicaría el stock a otra publicación.
  #
  # La consulta corre dentro del request, con el timeout corto de la cotización
  # (ver docs/guidelines/architecture.md §7.4): el usuario está esperando saber
  # si el vínculo es válido, y es una sola lectura sin efectos en el proveedor.
  class LinkExternalProduct < ApplicationPoro
    TIMEOUTS = { open: 4, read: 4 }.freeze
    # Lo que la búsqueda devuelve para describir la publicación. El resto de lo
    # que contesta son identificadores del canal y va a `external_refs`.
    DESCRIPTIVE_KEYS = %w[external_product_id external_sku external_title ambiguous_match].freeze

    Result = Struct.new(:mapping, :warnings)

    def initialize(product:, company_integration:, external_product_id: nil, external_price: nil)
      super()
      @product = product
      @integration = company_integration
      @external_product_id = external_product_id.to_s.strip.presence
      @external_price = external_price
    end

    def call
      found = @external_product_id ? look_up : search_by_sku
      mapping = @product.product_mappings.create!(
        company_integration: @integration, external_price: @external_price,
        external_product_id: found.fetch('external_product_id', @external_product_id).to_s,
        external_refs: found.except(*DESCRIPTIVE_KEYS)
      )
      SyncStockToChannelsJob.perform_later(@product.id, @product.company_id, @integration.id)
      Result.new(mapping, warnings(found))
    end

    private

    def service = @integration.service

    # Sin plantilla de búsqueda, el vínculo se crea con el id tal cual (el
    # comportamiento de siempre).
    def look_up
      template = service.template_for(:product_lookup)
      return {} if template.nil?

      found = run(template)
      return found if found.present?

      not_found!("#{@external_product_id} does not exist in #{service.service_name}")
    end

    def search_by_sku
      template = service.template_for(:product_search)
      not_found!('external_product_id is required') if template.nil?

      found = run(template)
      unless same_sku?(found['external_sku'])
        not_found!("no #{service.service_name} variant has the SKU #{@product.sku}")
      end
      not_found!("more than one variant has the SKU #{@product.sku}") if found['ambiguous_match']
      found
    end

    # El id viaja en el payload y en la URI: cada plantilla usa el que le sirve
    # (GraphQL lo manda como variable, una API REST lo lleva en el path).
    def run(template)
      ids = { external_id: @external_product_id }.compact
      Integrations::HttpAdapter.new(
        company_integration: @integration, service: template, timeouts: TIMEOUTS,
        payload: ids.merge(sku: @product.sku), uri_params: ids
      ).call
    end

    def same_sku?(external_sku)
      external_sku.to_s.strip.casecmp?(@product.sku.to_s.strip)
    end

    # 1 producto = 1 SKU es regla del MVP: un SKU distinto no bloquea (el
    # usuario puede estar corrigiéndolo) pero se avisa.
    def warnings(found)
      external_sku = found['external_sku']
      return [] if external_sku.blank? || same_sku?(external_sku)

      ["The #{service.service_name} SKU is #{external_sku}, the product SKU is #{@product.sku}"]
    end

    def not_found!(message)
      raise ExternalProductNotFoundError, message
    end
  end
end
