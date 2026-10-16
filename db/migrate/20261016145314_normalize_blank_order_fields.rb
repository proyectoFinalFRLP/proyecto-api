class NormalizeBlankOrderFields < ActiveRecord::Migration[8.1]
  # Desde TESIS-178 y 179, `Order` guarda un domicilio o un contacto en blanco
  # como NULL (`normalizes ... strip.presence`). Las órdenes anteriores pueden
  # tener `''` guardado, y lo conservaban hasta que alguien las editara: la
  # columna quedaba con dos formas de decir «sin dato». Esto las empareja.
  #
  # SQL directo y no un recorrido de modelos: es una corrección de datos de
  # una sola vez, no tiene que pasar por validaciones ni callbacks.
  COLUMNS = %w[customer_address customer_city customer_province customer_zip_code
               customer_email customer_phone].freeze

  def up
    COLUMNS.each do |column|
      execute "UPDATE orders SET #{column} = NULL WHERE btrim(#{column}) = ''"
    end
  end

  # Un NULL que antes era `''` no se puede distinguir de uno que siempre fue
  # NULL, y los dos significan lo mismo: no hay nada que revertir.
  def down; end
end
