# frozen_string_literal: true

class AddUniqueIndexToShipmentEvents < ActiveRecord::Migration[8.1]
  def change
    # La entrega de webhooks de couriers es at-least-once: el proveedor puede
    # reintentar el mismo evento y dos workers pueden llegar a procesarlo casi en
    # simultáneo. El chequeo de duplicado en Ruby (Shipments::ProcessTrackingUpdate)
    # corre bajo el lock de fila del shipment y cubre el caso normal, pero dos
    # transacciones que arrancan antes de que cualquiera tome el lock igual
    # podrían, en teoría, colarse las dos. Este índice único es la garantía a
    # nivel de motor: ante el mismo (shipment_id, external_status, occurred_at),
    # sólo una fila sobrevive y la otra transacción recibe
    # ActiveRecord::RecordNotUnique, que el PORO interpreta como "ya registrado".
    #
    # Nombre explícito: el que generaría Rails por default supera los 63
    # caracteres que soporta un identificador de PostgreSQL.
    add_index :shipment_events, %i[shipment_id external_status occurred_at],
              unique: true, name: 'index_shipment_events_on_shipment_and_event'
  end
end
