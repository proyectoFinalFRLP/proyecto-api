class AddExternalOrderNumberToOrders < ActiveRecord::Migration[8.1]
  # El número con el que la tienda nombra la venta (TESIS-180): en Shopify,
  # «#1001». Es sólo para mostrar y buscar; la identidad de la venta sigue
  # siendo `external_order_id`, por eso no lleva índice único.
  def change
    add_column :orders, :external_order_number, :string
  end
end
