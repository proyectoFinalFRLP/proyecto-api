# frozen_string_literal: true

module Shipments
  # Registra en la bitácora de un envío un movimiento ya traducido por
  # TranslateTrackingPayload y, si corresponde, avanza shipments.status.
  #
  # Es el núcleo que comparten las dos formas de enterarse de un movimiento: el
  # push del courier (ProcessTrackingUpdate, TESIS-48) y la consulta periódica a
  # los que no tienen webhooks (PollTrackingStatus, TESIS-49). Las reglas de
  # idempotencia y orden son las mismas venga de donde venga el dato; lo que
  # cambia es qué hace cada camino con el resultado.
  #
  # Devuelve el ShipmentEvent creado, o nil si el movimiento ya estaba
  # registrado o llegó desordenado.
  class RegisterTrackingEvent < ApplicationPoro
    def initialize(shipment:, translated:)
      super()
      @shipment = shipment
      @translated = translated
    end

    def call
      ActiveRecord::Base.transaction do
        # FOR UPDATE: serializa los eventos del mismo envío. Los chequeos de
        # duplicado/desorden van adentro del lock a propósito: afuera, dos
        # entregas simultáneas del mismo evento pasarían las dos.
        @shipment.lock!
        next if duplicate? || stale?

        event = ShipmentEvent.create!(event_attributes)
        @shipment.update!(status: @translated[:internal_status]) if advances_status?
        event
      end
    rescue ActiveRecord::RecordNotUnique
      # Otro worker ya escribió este mismo evento (mismo shipment_id +
      # external_status + occurred_at, ver índice único de la migración): la
      # bitácora ya lo tiene, no es un fallo.
      nil
    end

    private

    def event_attributes
      {
        shipment: @shipment,
        internal_status: internal_status,
        external_status: @translated[:external_status],
        description: @translated[:description],
        occurred_at: occurred_at
      }
    end

    # occurred_at es NOT NULL en la tabla; si el courier no lo mandó, usamos el
    # momento del procesamiento en lugar de fallar.
    def occurred_at
      @occurred_at ||= @translated[:occurred_at] || Time.current
    end

    # Si la plantilla no supo traducir el estado externo (no está en el
    # response_value_mapper, o el valor traducido no pertenece a
    # Shipment::STATUSES), el evento igual se registra, pero como puramente
    # informativo: conserva el último estado conocido del envío en vez de
    # perder el movimiento o inventar un estado.
    def internal_status
      @translated[:internal_status] || @shipment.status
    end

    def advances_status?
      @translated[:internal_status].present? &&
        @translated[:internal_status] != @shipment.status
    end

    def duplicate?
      return duplicate_without_timestamp? if @translated[:occurred_at].nil?

      @shipment.shipment_events.exists?(external_status: @translated[:external_status],
                                        occurred_at: occurred_at)
    end

    # Sin fecha del courier, occurred_at se sintetiza con Time.current en cada
    # entrega (ver occurred_at) y nunca coincide entre reintentos: comparar por
    # timestamp exacto no sirve para distinguir un reintento de un movimiento
    # legítimo. Para una bitácora de auditoría el default seguro es no duplicar,
    # así que acá se compara contra el último evento del envío por external_status.
    def duplicate_without_timestamp?
      last_event = @shipment.shipment_events.order(occurred_at: :desc).first
      last_event&.external_status == @translated[:external_status]
    end

    # Llegó desordenado: ya hay registrado un evento con occurred_at más nuevo
    # para este envío. Se descarta en lugar de pisar un estado más reciente.
    def stale?
      last_occurred_at = @shipment.shipment_events.maximum(:occurred_at)
      last_occurred_at.present? && occurred_at < last_occurred_at
    end
  end
end
