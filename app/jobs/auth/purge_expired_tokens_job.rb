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
    # entera; iterar sin techo dejaria el job colgado si algo va mal.
    #
    # 100 lotes = 100.000 filas por corrida. Eso alcanza mientras el ingreso
    # diario quede por debajo de ese numero: si se lo pasara, cada corrida
    # borraria 100.000 mientras llegan mas y la tabla creceria igual, que es el
    # problema que este job existe para evitar. Por eso el corte por techo se
    # loguea: es la senial de que hay que subir el numero o correrlo mas seguido.
    MAX_BATCHES = 100

    def perform
      # Iterar es lo que hace cierta la promesa de arriba: con un solo lote la
      # tabla dejaba de bajar apenas hubiera mas de BATCH_SIZE tokens vencidos
      # en un dia, que es justo el escenario que este job existe para evitar.
      MAX_BATCHES.times do
        deleted = JwtDenylist.expired.limit(BATCH_SIZE).delete_all
        return if deleted < BATCH_SIZE
      end

      # Se agoto el techo y todavia quedaban vencidos: silencioso, la tabla
      # seguiria creciendo sin que nadie se entere.
      Rails.logger.warn(
        "[PurgeExpiredTokensJob] techo de #{MAX_BATCHES} lotes alcanzado, quedan vencidos"
      )
    end
  end
end
