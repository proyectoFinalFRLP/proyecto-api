# frozen_string_literal: true

# Dos datos que el despacho ya conoce y no se guardaban: de qué depósito sale
# el paquete y para cuándo quedó comprometida la entrega.
#
# El depósito viajaba en el request del despacho y se usaba sólo para cotizar
# y pedir la etiqueta, así que el detalle de la orden mostraba «Depósito de
# origen» siempre vacío. La fecha comprometida sale de los días estimados de
# la opción que el operador eligió al cotizar: sin ella, Reportes no podía
# medir el cumplimiento de plazo ni decir qué envíos vienen demorados.
#
# Las dos son opcionales: los envíos despachados antes de esta migración no
# las tienen, y un courier puede cotizar sin plazo. Un envío sin fecha
# comprometida no cuenta ni a favor ni en contra del cumplimiento.
class AddOriginAndPromiseToShipments < ActiveRecord::Migration[8.1]
  def change
    add_reference :shipments, :origin_warehouse,
                  foreign_key: { to_table: :warehouses, on_delete: :restrict }
    add_column :shipments, :promised_delivery_on, :date
  end
end
