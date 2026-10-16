class AddLowStockThresholdToProducts < ActiveRecord::Migration[8.1]
  # Hasta cuántas unidades un producto está en stock bajo (TESIS-182). El
  # default es el umbral único que se usaba hasta ahora para todo el catálogo,
  # así que ningún producto existente cambia de estado al migrar.
  def change
    add_column :products, :low_stock_threshold, :integer, null: false, default: 100
    add_check_constraint :products, 'low_stock_threshold >= 0',
                         name: 'products_low_stock_threshold_non_negative'
  end
end
