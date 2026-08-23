# frozen_string_literal: true

class AddQuantityCheckConstraintToStocks < ActiveRecord::Migration[8.1]
  def change
    # Red de seguridad a nivel DB contra escrituras concurrentes que se salteen las validaciones
    # del modelo (ej: update_all, upsert_all, SQL crudo). Las validaciones de ActiveRecord
    # no se ejecutan en esos casos, pero el constraint a nivel DB siempre protege la integridad.
    add_check_constraint :stocks, 'quantity >= 0', name: 'stocks_quantity_non_negative'
  end
end
