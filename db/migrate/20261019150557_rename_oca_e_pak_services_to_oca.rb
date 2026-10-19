# frozen_string_literal: true

# Las plantillas de OCA se llaman «OCA», como «Andreani» o «Correo Argentino»:
# «e-Pak» es el nombre del producto de OCA que se integra, no algo que el
# operador tenga que leer en la cotización o en el detalle del envío
# (TESIS-188). Los seeds ya las crean con el nombre nuevo; esto renombra las de
# una base sembrada antes, conservando sus ids y las integraciones conectadas.
class RenameOcaEPakServicesToOca < ActiveRecord::Migration[8.1]
  def up
    rename('OCA e-Pak', 'OCA')
  end

  def down
    rename('OCA', 'OCA e-Pak')
  end

  private

  # La madre y sus plantillas: `OCA e-Pak` y `OCA e-Pak - <operación>`.
  def rename(from, to)
    execute <<~SQL.squish
      UPDATE services SET service_name = #{quote(to)} || substring(service_name from #{from.length + 1})
      WHERE service_name = #{quote(from)} OR service_name LIKE #{quote("#{from} - %")}
    SQL
  end
end
