# frozen_string_literal: true

class OrderItemSerializer < ApplicationSerializer
  identifier :id

  fields :quantity, :product_id, :created_at, :updated_at

  # unit_price es decimal en la DB y BigDecimal se serializa como string por
  # defecto; exponerlo como número evita que el front tenga que parsear.
  field :unit_price do |item|
    item.unit_price.to_f
  end

  # El producto de la línea, para que el detalle de la orden pueda mostrar qué
  # se vendió sin un request por ítem (TESIS-112). Sólo lo identificatorio: el
  # detalle completo del producto es GET /products/:id.
  #
  # Los dos endpoints que serializan ítems precargan `order_items: :product`,
  # así que esto no dispara una consulta por línea.
  field :product do |item|
    { id: item.product_id, sku: item.product.sku, name: item.product.name }
  end
end
