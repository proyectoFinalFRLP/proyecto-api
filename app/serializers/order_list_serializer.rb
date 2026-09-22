# frozen_string_literal: true

# Fila del listado de órdenes. Liviano a propósito: las líneas de la orden y su
# producto sólo viajan en el detalle (OrderSerializer), igual que el desglose de
# stock por depósito viaja en ProductSerializer y no en ProductListSerializer.
class OrderListSerializer < ApplicationSerializer
  identifier :id

  # La columna Destino del listado (TESIS-52). La dirección y el código postal
  # vienen desde el principio; la ciudad y la provincia desde TESIS-128, así que
  # las órdenes anteriores y las de webhook las traen en null.
  fields :customer_name, :customer_document, :customer_address, :customer_zip_code,
         :customer_city, :customer_province, :external_order_id, :status, :created_at, :updated_at

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
  # Se llama `courier` y tiene la misma forma que en los dos endpoints de
  # envíos, porque es el mismo dato. Antes viajaba como `carrier` y como string
  # suelto: dos nombres y dos formas para un solo concepto obligaban al front a
  # modelarlo dos veces.
  #
  # El controller precarga `shipment: { company_integration: :service }`, así
  # que resolverlo no dispara consultas por fila.
  courier_field(:courier, &:courier)

  # Cuántas líneas tiene la orden, para la columna del listado. Se lee de la
  # asociación ya precargada por el controller (`size` y no `count`: sobre una
  # asociación cargada cuenta en memoria, mientras que `count` dispararía un
  # SELECT COUNT por fila).
  field :item_count do |order|
    order.order_items.size
  end
end
