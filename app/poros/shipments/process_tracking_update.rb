# frozen_string_literal: true

module Shipments
  # Convierte un WebhookLog crudo de push tracking en un movimiento de envío:
  # traduce el payload con la plantilla del Service, localiza el Shipment por
  # tracking_number y registra el evento. shipments.status sólo avanza cuando el
  # courier mandó un estado que la plantilla sabe traducir a nuestro vocabulario.
  #
  # Igual que Orders::ProcessWebhookOrder (TESIS-43): el resultado —bueno o
  # malo— se persiste en el propio WebhookLog (`processed` / `failed` +
  # error_message) y la excepción se re-levanta después de marcarlo: quien
  # invoca decide qué hacer con el fallo (el job la deriva a la DLQ).
  class ProcessTrackingUpdate < ApplicationPoro
    class InvalidPayloadError < StandardError; end

    MISSING_TRACKING_NUMBER = 'the payload does not carry a tracking number'
    MISSING_EXTERNAL_STATUS = 'the payload does not carry an external status'

    def initialize(webhook_log:)
      super()
      @log = webhook_log
    end

    def call
      # El courier reintenta la entrega (at-least-once) y el job puede correr
      # más de una vez para el mismo log: uno ya procesado no se vuelve a tocar.
      return if @log.processed?

      event = apply
      mark_processed
      event
    rescue StandardError => e
      mark_failed(e)
      raise
    end

    private

    def apply
      validate_payload!
      shipment = find_shipment
      # Tracking ajeno: no es un error nuestro, es el courier avisando de un
      # paquete que no es nuestro. No hay nada que reintentar ni reportar: el
      # log queda `processed` para que el proveedor deje de insistir.
      return unless shipment

      register_event(shipment)
    end

    def register_event(shipment)
      ActiveRecord::Base.transaction do
        # FOR UPDATE: serializa los eventos del mismo envío. Los chequeos de
        # duplicado/desorden van adentro del lock a propósito: afuera, dos
        # entregas simultáneas del mismo evento pasarían las dos.
        shipment.lock!
        next if duplicate?(shipment) || stale?(shipment)

        event = ShipmentEvent.create!(event_attributes(shipment))
        shipment.update!(status: translated[:internal_status]) if advances_status?(shipment)
        event
      end
    rescue ActiveRecord::RecordNotUnique
      # Otro worker ya escribió este mismo evento (mismo shipment_id +
      # external_status + occurred_at, ver índice único de la migración): la
      # bitácora ya lo tiene, no es un fallo.
      nil
    end

    def find_shipment
      Shipment.find_by(tracking_number: translated[:tracking_number],
                       company_integration_id: @log.company_integration_id)
    end

    def event_attributes(shipment)
      {
        shipment: shipment,
        internal_status: internal_status_for(shipment),
        external_status: translated[:external_status],
        description: translated[:description],
        occurred_at: occurred_at
      }
    end

    # occurred_at es NOT NULL en la tabla; si el courier no lo mandó en el
    # payload, usamos el momento del procesamiento en lugar de fallar.
    def occurred_at
      @occurred_at ||= translated[:occurred_at] || Time.current
    end

    # Si la plantilla no supo traducir el estado externo (no está en el
    # response_value_mapper, o el valor traducido no pertenece a
    # Shipment::STATUSES), el evento igual se registra, pero como puramente
    # informativo: conserva el último estado conocido del envío en vez de
    # perder el movimiento o inventar un estado.
    def internal_status_for(shipment)
      translated[:internal_status] || shipment.status
    end

    def advances_status?(shipment)
      translated[:internal_status].present? && translated[:internal_status] != shipment.status
    end

    def duplicate?(shipment)
      return duplicate_without_timestamp?(shipment) if translated[:occurred_at].nil?

      shipment.shipment_events.exists?(external_status: translated[:external_status],
                                       occurred_at: occurred_at)
    end

    # Sin fecha del courier, occurred_at se sintetiza con Time.current en cada
    # entrega (ver occurred_at) y nunca coincide entre reintentos: comparar por
    # timestamp exacto no sirve para distinguir un reintento de un movimiento
    # legítimo. Para una bitácora de auditoría el default seguro es no duplicar,
    # así que acá se compara contra el último evento del envío por external_status.
    def duplicate_without_timestamp?(shipment)
      last_event = shipment.shipment_events.order(occurred_at: :desc).first
      last_event&.external_status == translated[:external_status]
    end

    # Llegó desordenado: ya hay registrado un evento con occurred_at más nuevo
    # para este envío. Se descarta en lugar de pisar un estado más reciente.
    def stale?(shipment)
      last_occurred_at = shipment.shipment_events.maximum(:occurred_at)
      last_occurred_at.present? && occurred_at < last_occurred_at
    end

    # Esto sí es un error real que va a la DLQ: no es un paquete ajeno (eso lo
    # resuelve find_shipment más adelante), es una plantilla del Service mal
    # configurada —no ubica el tracking_number o el estado en el payload— y
    # alguien tiene que enterarse y corregirla, no reintentarla sola.
    def validate_payload!
      raise InvalidPayloadError, MISSING_TRACKING_NUMBER if translated[:tracking_number].blank?
      raise InvalidPayloadError, MISSING_EXTERNAL_STATUS if translated[:external_status].blank?
    end

    def translated
      @translated ||= TranslateTrackingPayload
                      .new(service: @log.company_integration.service, payload: @log.payload).call
    end

    def mark_processed
      @log.update!(status: :processed, error_message: nil)
    end

    # Fuera de la transacción de negocio: si ésta hizo rollback, el registro
    # del error tiene que sobrevivir, no desaparecer arrastrado por él.
    def mark_failed(error)
      detail = "#{error.class}: #{error.message}".truncate(WebhookLog::ERROR_LIMIT)
      @log.update!(status: :failed, error_message: detail)
    end
  end
end
