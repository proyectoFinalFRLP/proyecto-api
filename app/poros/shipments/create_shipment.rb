# frozen_string_literal: true

module Shipments
  # Da de alta el envío de una orden: el punto de entrada de la épica logística
  # (TESIS-105). Hasta esta card se podía cotizar un envío (TESIS-46), despacharlo
  # (TESIS-47) y seguirlo por webhook (TESIS-48); lo único que no se podía era
  # tenerlo — los únicos envíos de la base los sembraba db/seeds.rb.
  #
  # El envío nace 'pending' y sin courier: el operador, el número de seguimiento
  # y el costo los completa la confirmación del despacho (TESIS-47). Este caso de
  # uso no elige operador ni cotiza, sólo abre el circuito.
  class CreateShipment < ApplicationPoro
    # Una orden cancelada no se despacha; el resto sí.
    #
    # Es una lista de exclusión y no la inclusión de 'paid' que pedía el alcance
    # de la card: hoy nada en la aplicación mueve una orden a 'paid' —CreateOrder
    # la crea 'pending' (TESIS-42) y ProcessWebhookOrder sólo llega a 'paid' si el
    # canal lo manda (TESIS-43)—, así que exigirlo habría dejado el endpoint
    # inalcanzable justo para el alta manual que necesita el wizard de TESIS-59.
    # Cuando exista la transición de estados, esta constante es el único lugar a
    # tocar.
    NON_SHIPPABLE_STATUSES = %w[cancelled].freeze

    # Redundante con el default de la columna (TESIS-45) y a propósito: el estado
    # inicial es parte del contrato de este caso de uso, no un detalle del schema.
    # Mismo criterio que Orders::CreateOrder con el status de la orden.
    INITIAL_STATUS = 'pending'

    def initialize(order:)
      super()
      @order = order
    end

    def call
      validate_status!
      create_shipment
    end

    private

    def validate_status!
      return unless NON_SHIPPABLE_STATUSES.include?(@order.status)

      raise UnshippableOrderError.new(order: @order)
    end

    # Una sola escritura: sin transacción explícita, porque un choque contra la
    # restricción 1 a 1 no deja nada a medias que revertir.
    #
    # Sin `exists?` previo, como pide la card: entre esa consulta y el INSERT hay
    # una ventana en la que otro request puede insertar el envío, y las dos
    # llamadas terminarían devolviendo 201. La verdad la dice el intento de
    # escritura, que falla por dos caminos distintos:
    #
    #   - `validates :order_id, uniqueness: true` (TESIS-45) atrapa el caso
    #     normal antes de tocar la base: RecordInvalid con el error :taken.
    #   - el índice único sobre order_id atrapa la carrera real, cuando las dos
    #     transacciones pasan la validación antes de que cualquiera confirme:
    #     RecordNotUnique.
    #
    # Son el mismo hecho de negocio, así que salen como el mismo error y el mismo
    # 409. Cualquier otro RecordInvalid (una orden de otra empresa, por ejemplo)
    # sigue de largo: es un 422 y no un conflicto.
    def create_shipment
      Shipment.create!(company: @order.company, order: @order, status: INITIAL_STATUS)
    rescue ActiveRecord::RecordInvalid => e
      raise unless e.record.errors.of_kind?(:order_id, :taken)

      raise DuplicateShipmentError.new(order_id: @order.id)
    rescue ActiveRecord::RecordNotUnique
      raise DuplicateShipmentError.new(order_id: @order.id)
    end
  end
end
