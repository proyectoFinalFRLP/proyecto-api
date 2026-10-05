# frozen_string_literal: true

class AddExternalRefsToProductMappings < ActiveRecord::Migration[8.1]
  # Otros identificadores de la publicación en el canal, además del que llega en
  # las ventas (`external_product_id`). Shopify vende por variante pero publica
  # el stock por `inventory_item_id`: el vínculo necesita los dos. Es genérico a
  # propósito: otro canal puede necesitar otros (Tiendanube, producto + variante).
  #
  # Lo completa la plantilla de búsqueda del proveedor al vincular, y el sync
  # saliente lo suma al payload para que el request_mapper lo use.
  def change
    add_column :product_mappings, :external_refs, :jsonb, default: {}, null: false
  end
end
