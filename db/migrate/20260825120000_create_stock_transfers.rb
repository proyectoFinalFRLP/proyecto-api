# frozen_string_literal: true

class CreateStockTransfers < ActiveRecord::Migration[8.1]
  def change
    create_table :stock_transfers do |t|
      t.references :company, null: false, foreign_key: { on_delete: :cascade }
      # RESTRICT y no cascade: una transferencia es el registro de un movimiento
      # de unidades reales. Si se pudiera borrar el producto o el depósito con
      # transferencias vivas, quedarían unidades descontadas del origen sin
      # rastro de a dónde iban. Mismo criterio que order_items -> products.
      t.references :product, null: false, foreign_key: { on_delete: :restrict }
      t.references :origin_warehouse, null: false,
                                      foreign_key: { to_table: :warehouses, on_delete: :restrict }
      t.references :destination_warehouse, null: false,
                                           foreign_key: { to_table: :warehouses,
                                                          on_delete: :restrict }
      t.integer :quantity, null: false
      t.string :status, null: false, default: 'in_transit'
      # Cuándo salieron las unidades del origen. NOT NULL porque crear la
      # transferencia ES despacharla: no existe el estado borrador.
      t.datetime :dispatched_at, null: false
      # Cuándo se resolvió (recibida o cancelada). Nulo mientras está en vuelo.
      t.datetime :settled_at

      t.timestamps
    end

    add_check_constraint :stock_transfers, 'quantity > 0',
                         name: 'stock_transfers_quantity_positive'
    add_check_constraint :stock_transfers,
                         "status IN ('in_transit', 'received', 'cancelled')",
                         name: 'stock_transfers_status_check'
    add_check_constraint :stock_transfers,
                         'origin_warehouse_id <> destination_warehouse_id',
                         name: 'stock_transfers_distinct_warehouses'

    # El listado del catálogo suma las unidades en vuelo por producto, siempre
    # dentro de una empresa y siempre filtrando por estado.
    add_index :stock_transfers, %i[company_id status product_id]
  end
end
