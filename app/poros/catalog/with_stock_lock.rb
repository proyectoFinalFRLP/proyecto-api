# frozen_string_literal: true

require 'digest'

module Catalog
  # Serializa toda mutación de stock de un producto con un advisory lock de
  # PostgreSQL. A diferencia del locking optimista de ActiveRecord (que sólo
  # detecta el conflicto después de que ya ocurrió), acá dos procesos que tocan
  # el mismo producto se serializan directamente en la base.
  #
  # Alcance: sirve para read-modify-write sobre el stock — leer la cantidad
  # actual, calcular la nueva y escribirla — que es lo que va a hacer el
  # descuento de stock al confirmar una orden. NO resuelve el "lost update" de
  # dos ediciones concurrentes del ABM, porque ahí la cantidad llega absoluta
  # desde el request y serializar no cambia cuál gana: eso pide detección
  # (lock_version / If-Match), no exclusión mutua.
  #
  # Usamos la variante "xact" (pg_advisory_xact_lock) y no la de sesión
  # (pg_advisory_lock): el lock de sesión sobrevive al fin de la transacción y
  # hay que liberarlo a mano, lo que deja locks huérfanos si el proceso muere
  # entre la adquisición y el unlock (worker matado, crash, etc). El lock de
  # transacción se libera solo en COMMIT/ROLLBACK: no hay forma de dejarlo colgado.
  class WithStockLock < ApplicationPoro
    DEFAULT_TIMEOUT_MS = 3_000
    DEFAULT_NAMESPACE = 'stock'

    def initialize(product_id:, wait: true, timeout_ms: DEFAULT_TIMEOUT_MS,
                   namespace: DEFAULT_NAMESPACE)
      super()
      @product_id = product_id
      @wait = wait
      @timeout_ms = timeout_ms
      @namespace = namespace
    end

    # pg_advisory_xact_lock sólo tiene efecto dentro de una transacción (se
    # libera en el commit/rollback). Si el caller ya abrió una, Rails la
    # reutiliza acá y el lock se sostiene hasta que esa transacción externa
    # termine; eso es intencional, no un bug.
    def call
      ActiveRecord::Base.transaction do
        @wait ? acquire_waiting! : acquire_immediately!
        yield
      end
    end

    # La clave no lleva company_id: products.id es una PK global, así que dos
    # empresas nunca comparten un product_id y el tenant no agregaría ningún
    # aislamiento. El namespace deja lugar para futuros recursos bloqueables
    # (por ejemplo la confirmación de una orden) sin colisionar con las claves
    # de stock. SHA-256 sobre "namespace:product_id", primeros 8 bytes como
    # entero con signo de 64 bits, que es el tipo que espera
    # pg_advisory_xact_lock.
    def lock_key
      @lock_key ||= compute_lock_key
    end

    private

    # Modo pensado para jobs de background: vale la pena esperar unos segundos
    # a que se libere el lock antes de reintentar todo el job desde afuera.
    # lock_timeout acota esa espera para no colgar el worker si algo no suelta
    # el lock nunca.
    def acquire_waiting!
      previous_timeout = connection.select_value('SHOW lock_timeout')
      apply_lock_timeout!
      connection.execute("SELECT pg_advisory_xact_lock(#{lock_key.to_i})")
      # Sólo restauramos si se obtuvo el lock: si venció el timeout la
      # transacción queda abortada (55P03) y cualquier SET LOCAL posterior
      # fallaría con PG::InFailedSqlTransaction. El rollback de esa
      # transacción descarta el SET LOCAL de todos modos.
      restore_lock_timeout(previous_timeout)
    rescue ActiveRecord::LockWaitTimeout
      raise LockTimeoutError.new(product_id: @product_id, lock_key: lock_key)
    end

    # Modo pensado para requests HTTP interactivos: nadie quiere esperar varios
    # segundos a que se libere un lock ajeno. Preferimos fallar ya con 409 y
    # que el cliente decida si reintenta.
    def acquire_immediately!
      acquired = connection.select_value("SELECT pg_try_advisory_xact_lock(#{lock_key.to_i})")
      return if ActiveModel::Type::Boolean.new.cast(acquired)

      raise LockTimeoutError.new(product_id: @product_id, lock_key: lock_key)
    end

    def apply_lock_timeout!
      quoted_timeout = connection.quote("#{@timeout_ms.to_i}ms")
      connection.execute("SET LOCAL lock_timeout = #{quoted_timeout}")
    end

    def restore_lock_timeout(previous_value)
      connection.execute("SET LOCAL lock_timeout = #{connection.quote(previous_value)}")
    end

    def compute_lock_key
      Digest::SHA256.digest("#{@namespace}:#{@product_id}").unpack1('q>')
    end

    def connection
      ActiveRecord::Base.connection
    end
  end
end
