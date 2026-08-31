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

    def perform
      JwtDenylist.expired.limit(BATCH_SIZE).delete_all
    end
  end
end
