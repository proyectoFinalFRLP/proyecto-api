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

    # Las reglas de idempotencia, orden y transaccionalidad viven en
    # RegisterTrackingEvent: son las mismas para la consulta periódica (TESIS-49).
    def register_event(shipment)
      RegisterTrackingEvent.new(shipment: shipment, translated: translated).call
    end

    def find_shipment
      Shipment.find_by(tracking_number: translated[:tracking_number],
                       company_integration_id: @log.company_integration_id)
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
