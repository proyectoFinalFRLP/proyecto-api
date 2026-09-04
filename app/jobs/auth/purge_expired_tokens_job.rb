# frozen_string_literal: true

module Auth
  # Borra de la lista de revocación los tokens ya vencidos.
  #
  # Una fila cuyo `exp` pasó no cambia ninguna decisión: ese token no autentica
  # por vencido, con denylist o sin ella. Sin esta limpieza la tabla crece con
  # cada cierre de sesión y nunca baja.
  #
  # Corre fuera de todo contexto de tenant, como el barrido de la DLQ: la
  # revocación es por token, no por empresa.
  class PurgeExpiredTokensJob < ApplicationJob
    queue_as :low

    BATCH_SIZE = 1_000

    # Techo de la corrida. Un solo `delete_all` sin `limit` bloquearia la tabla
    # entera; iterar sin techo dejaria el job colgado si algo va mal. Con estos
    # numeros una corrida limpia hasta 100.000 filas y, si quedaran mas, las
    # levanta la del dia siguiente.
    MAX_BATCHES = 100

    def perform
      # Iterar es lo que hace cierta la promesa de arriba: con un solo lote la
      # tabla dejaba de bajar apenas hubiera mas de BATCH_SIZE tokens vencidos
      # en un dia, que es justo el escenario que este job existe para evitar.
      MAX_BATCHES.times do
        deleted = JwtDenylist.expired.limit(BATCH_SIZE).delete_all
        break if deleted < BATCH_SIZE
      end
    end
  end
end
