# frozen_string_literal: true

class AddTotalAmountToOrders < ActiveRecord::Migration[8.1]
  # Backfill del histórico: cada orden queda con lo que suman sus líneas. Las
  # órdenes sin líneas quedan en NULL y no en 0, porque no hay con qué
  # calcularlas y un 0 sería indistinguible de una venta bonificada.
  BACKFILL = <<~SQL.squish
    UPDATE orders
    SET total_amount = totals.amount
    FROM (
      SELECT order_id, SUM(quantity * unit_price) AS amount
      FROM order_items
      GROUP BY order_id
    ) AS totals
    WHERE orders.id = totals.order_id
  SQL

  def up
    # nullable y no `null: false` con default: una orden recién creada vive un
    # instante sin líneas dentro de la transacción que la crea, y las órdenes
    # preexistentes sin líneas no tienen un total que escribirles. Misma
    # precisión que order_items.unit_price y shipments.shipping_cost.
    add_column :orders, :total_amount, :decimal, precision: 10, scale: 2

    execute BACKFILL

    # Red de seguridad a nivel DB contra escrituras que se salteen las
    # validaciones del modelo (update_all, upsert_all, SQL crudo), mismo
    # criterio que stocks_quantity_non_negative.
    add_check_constraint :orders, 'total_amount >= 0',
                         name: 'orders_total_amount_non_negative'
  end

  def down
    remove_check_constraint :orders, name: 'orders_total_amount_non_negative'
    remove_column :orders, :total_amount
  end
end
