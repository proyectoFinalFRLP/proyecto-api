# El último intento de publicar el stock de un producto en un canal (TESIS-177).
# Sin esto, un sync que falla sólo queda en solid_queue_failed_executions y
# nadie se entera: la tarjeta «Canales de venta» del producto lo muestra con el
# motivo, y la pantalla de integraciones cuenta los vínculos que fallan.
class AddSyncStatusToProductMappings < ActiveRecord::Migration[8.1]
  def change
    change_table :product_mappings, bulk: true do |t|
      t.datetime :last_synced_at
      t.text :last_sync_error
    end
  end
end
