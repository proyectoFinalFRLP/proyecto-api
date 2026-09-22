# frozen_string_literal: true

class AddWarehouseToOrderItems < ActiveRecord::Migration[8.1]
  # El depósito del que salió cada línea (TESIS-126). El alta ya lo conocía
  # —CreateOrder lo recibe en el request y el picking de DeductStock lo elige—
  # pero lo descartaba después de descontar: mientras la orden no se editaba,
  # nadie lo necesitaba. Para modificar una orden sí hace falta, porque bajar la
  # cantidad de una línea es devolver unidades, y hay que saber a dónde.
  #
  # Nullable y sin backfill: el descuento de las líneas anteriores no dejó rastro
  # de a qué depósito le pegó, así que no hay dato que recuperar. Inventarlo
  # (por ejemplo, el primer depósito con stock) sería peor que no tenerlo: una
  # devolución a un depósito equivocado deja el inventario mal sin que nada lo
  # delate. Esas líneas quedan en NULL y la modificación las rechaza cuando
  # tendría que devolverles unidades.
  def change
    # restrict, como la FK hermana a products: un depósito del que salieron
    # ventas no se borra por debajo de sus líneas. El modelo lo traduce a 409.
    add_reference :order_items, :warehouse, foreign_key: { on_delete: :restrict }, index: true
  end
end
