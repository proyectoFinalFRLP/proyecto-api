# frozen_string_literal: true

# Dos estados finales más para un envío (TESIS-188): `returned` (el courier lo
# devolvió al remitente) y `cancelled` (el courier lo anuló, o lo dio por
# perdido). Sin ellos un envío que OCA informa «Devuelto al Remitente» o
# «Anulado» quedaba en curso para siempre, y la consulta periódica lo seguía
# preguntando cada 30 minutos (ADR-014).
#
# La CHECK de `shipment_events.internal_status` acompaña a la de `shipments`:
# el evento que registra el cambio lleva el mismo estado.
class AddReturnedAndCancelledToShipmentStatuses < ActiveRecord::Migration[8.1]
  STATUSES = %w[pending ready_to_ship in_transit delivered returned cancelled].freeze
  PREVIOUS = %w[pending ready_to_ship in_transit delivered].freeze

  CHECKS = { shipments: %w[status shipments_status_check],
             shipment_events: %w[internal_status shipment_events_internal_status_check] }.freeze

  def up
    CHECKS.each { |table, (column, name)| replace_check(table, column, name, STATUSES) }
  end

  # NOT VALID al volver: los envíos que ya terminaron devueltos o anulados no
  # cumplen la CHECK vieja, y reescribirlos sería inventarles un estado. Rige
  # para lo que se escriba después.
  def down
    CHECKS.each do |table, (column, name)|
      replace_check(table, column, name, PREVIOUS, validate: false)
    end
  end

  private

  def replace_check(table, column, name, statuses, validate: true)
    remove_check_constraint table, name: name
    values = statuses.map { connection.quote(it) }.join(', ')
    add_check_constraint table, "#{column} IN (#{values})", name: name, validate: validate
  end
end
