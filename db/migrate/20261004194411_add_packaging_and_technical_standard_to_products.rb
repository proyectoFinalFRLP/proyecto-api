# frozen_string_literal: true

# Empaque y norma técnica del producto. El detalle los muestra desde el diseño
# y hasta ahora decía que no existían en la API.
#
# Texto libre y no un vocabulario cerrado como `category`: una norma técnica es
# un código de un organismo externo (IRAM, IEC) y el empaque describe el bulto
# con las palabras del rubro. Encerrarlos en una lista nuestra dejaría afuera el
# caso que importa el día que aparezca.
class AddPackagingAndTechnicalStandardToProducts < ActiveRecord::Migration[8.1]
  def change
    add_column :products, :packaging, :string
    add_column :products, :technical_standard, :string
  end
end
