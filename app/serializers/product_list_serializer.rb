# frozen_string_literal: true

class ProductListSerializer < ApplicationSerializer
  identifier :id

  fields :sku, :name, :description, :category, :dimensions, :total_stock,
         :in_transit_quantity, :created_at, :updated_at

  # weight es decimal en la DB y BigDecimal se serializa como string por
  # defecto; exponerlo como número evita que el front tenga que parsear.
  field :weight do |product|
    product.weight.to_f
  end

  # Nodo principal para la columna "Location Node" del listado. El desglose
  # completo por depósito NO va acá: eso lo da GET /products/:id con
  # ProductSerializer, y mantener esa diferencia es lo que justifica que existan
  # dos serializers. Acá va lo que la fila necesita mostrar y nada más.
  #
  # nil cuando el producto no tiene unidades en ningún depósito: la fila no
  # tiene nodo que mostrar, y no es lo mismo que tener 0 en uno conocido.
  field :primary_warehouse do |product|
    stock = product.primary_stock
    next nil if stock.nil?

    { id: stock.warehouse_id, name: stock.warehouse.name, quantity: stock.quantity }
  end

  # Cuenta los depósitos con unidades, no las filas de stock: una asignación en
  # 0 no es un nodo donde el producto esté. Así `warehouse_count` es coherente
  # con `primary_warehouse` — si es 0, el otro es nil.
  field :warehouse_count do |product|
    product.stocks.count { |stock| stock.quantity.positive? }
  end
end
