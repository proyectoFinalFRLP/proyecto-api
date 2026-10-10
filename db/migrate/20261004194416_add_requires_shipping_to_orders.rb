# frozen_string_literal: true

# Si la orden se despacha o la retira el cliente. Hasta ahora toda orden se
# asumía despachada, y no había forma de registrar una venta con retiro en el
# local (TESIS-162).
#
# `default: true` y `null: false`: las órdenes que ya existen se despachan —es
# lo único que el sistema sabía hacer— y el default cubre el caso en que el
# canal no informa nada. Asumir envío y que sobre es recuperable; asumir retiro
# y que falte deja una venta sin despachar sin que nadie se entere.
class AddRequiresShippingToOrders < ActiveRecord::Migration[8.1]
  def change
    add_column :orders, :requires_shipping, :boolean, default: true, null: false
  end
end
