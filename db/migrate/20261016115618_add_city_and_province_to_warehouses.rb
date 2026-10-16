# frozen_string_literal: true

# Localidad y provincia del depósito (TESIS-185). Los couriers piden el origen
# del envío desglosado —OCA, por ejemplo, separa localidad y provincia del
# remitente— y hasta acá el depósito sólo tenía código postal y una dirección
# en texto libre.
#
# Nullable a propósito, como la capacidad: los depósitos que ya existen no las
# tienen cargadas y no hay de dónde sacarlas sin adivinar. La provincia se
# valida en el modelo contra `Order::PROVINCES`, igual que la de la orden.
class AddCityAndProvinceToWarehouses < ActiveRecord::Migration[8.1]
  def change
    add_column :warehouses, :city, :string
    add_column :warehouses, :province, :string
  end
end
