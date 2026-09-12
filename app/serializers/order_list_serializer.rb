# frozen_string_literal: true

# Fila del listado de órdenes. Liviano a propósito: las líneas de la orden y su
# producto sólo viajan en el detalle (OrderSerializer), igual que el desglose de
# stock por depósito viaja en ProductSerializer y no en ProductListSerializer.
class OrderListSerializer < ApplicationSerializer
  identifier :id

  # customer_address y customer_zip_code alimentan la columna Destino del
  # listado (TESIS-52). Son los dos únicos datos de ubicación que el modelo
  # tiene: no hay ciudad ni provincia, así que la pantalla muestra la dirección
  # con el código postal debajo.
  fields :customer_name, :customer_document, :customer_address, :customer_zip_code,
         :external_order_id, :status, :created_at, :updated_at

  # La columna Total del listado (TESIS-52). Sale de la columna persistida y no
  # de sumar las líneas: sumarlas por fila sería un SELECT por orden, y además
  # daría el precio de hoy en vez del que se facturó (TESIS-114).
  field :total_amount do |order|
    order.total_amount&.to_f
  end

  # El courier que lleva la orden, para la columna «Operador logístico» del
  # listado (TESIS-52). Viaja `null` cuando la orden no tiene envío o el envío
  # todavía no tiene courier asignado; la pantalla decide cómo mostrarlo.
  #
  # El controller precarga `shipment: { company_integration: :service }`, así
  # que `carrier_name` no dispara consultas por fila.
  field :carrier_name, name: :carrier

  # Cuántas líneas tiene la orden, para la columna del listado. Se lee de la
  # asociación ya precargada por el controller (`size` y no `count`: sobre una
  # asociación cargada cuenta en memoria, mientras que `count` dispararía un
  # SELECT COUNT por fila).
  field :item_count do |order|
    order.order_items.size
  end
end
