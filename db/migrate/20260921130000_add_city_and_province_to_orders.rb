# frozen_string_literal: true

class AddCityAndProvinceToOrders < ActiveRecord::Migration[8.1]
  # Ciudad y provincia del destino (TESIS-128). Nullable: las órdenes anteriores
  # no tienen el dato y las de webhook todavía no lo traen. Que el operador las
  # complete en el alta manual lo exige el formulario del front (TESIS-58).
  def change
    change_table :orders, bulk: true do |t|
      t.string :customer_city
      t.string :customer_province
    end
  end
end
