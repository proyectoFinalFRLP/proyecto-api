# frozen_string_literal: true

module Shipments
  # Traduce el payload crudo de un webhook de courier al vocabulario interno usando la
  # plantilla del Service.
  #
  # Por qué no delegamos derecho en Integrations::ParseExternalResponse: ese PORO aplica el
  # response_value_mapper a TODOS los valores que extrae, así que el resultado ya vendría con
  # el estado traducido y perderíamos el dato crudo. La card exige conservar los dos: el
  # external_status tal cual lo mandó el courier (bitácora/auditoría) y el internal_status
  # normalizado (para actualizar shipments.status). Por eso acá cada valor se lee crudo con
  # ParseExternalResponse.dig_path y la traducción de estado se hace aparte, a mano.
  class TranslateTrackingPayload < ApplicationPoro
    # Claves internas que reconoce la plantilla de tracking. Cualquier otra entrada del
    # response_mapper del Service se ignora: este PORO sólo entiende el vocabulario de un
    # evento de tracking, y la misma plantilla puede describir además otras operaciones del
    # proveedor (la respuesta del despacho, por ejemplo).
    TRACKING_KEYS = %w[tracking_number external_status occurred_at description].freeze

    # Marcador que una plantilla usa para describir una lista dentro del payload
    # ("order_items[].quantity"). Un push de tracking siempre habla de un evento
    # suelto, así que esas entradas no le sirven y se descartan al invertir el
    # mapper: sin el filtro, una plantilla que mezcle ambas formas podría hacer
    # que la ruta de una lista gane sobre la del valor suelto.
    COLLECTION_MARKER = '[]'

    def initialize(service:, payload:)
      super()
      @service = service
      @payload = payload
    end

    def call
      # TRACKING_KEYS acota qué se lee: cualquier otra clave que traiga el response_mapper
      # del Service (pensado para otras plantillas, p.ej. de órdenes) se ignora acá.
      raw = TRACKING_KEYS.index_with { |key| raw_value_for(key) }

      {
        tracking_number: raw['tracking_number']&.to_s,
        external_status: raw['external_status']&.to_s,
        internal_status: internal_status_for(raw['external_status']&.to_s),
        occurred_at: parse_occurred_at(raw['occurred_at']),
        description: raw['description']&.to_s
      }
    end

    private

    # Lee el valor tal cual llegó (sin pasar por el response_value_mapper) de la ruta externa
    # que el Service mapea a esta clave interna.
    def raw_value_for(internal_key)
      path = external_path_for(internal_key)
      return nil unless path

      Integrations::ParseExternalResponse.dig_path(@payload, path)
    end

    # Invierte el response_mapper (ruta externa => clave interna) para encontrar la ruta que
    # alimenta esta clave interna.
    def external_path_for(internal_key)
      single_event_mapper.key(internal_key)
    end

    def single_event_mapper
      @single_event_mapper ||= @service.response_mapper.reject do |path, _internal_key|
        path.include?(COLLECTION_MARKER)
      end
    end

    # internal_status se calcula aparte del resto de las claves: sólo vale si el estado
    # externo está mapeado en la plantilla Y el resultado es un estado que el OMS reconoce.
    # Si el courier manda un estado nuevo que la plantilla no contempla (o el mapper apunta a
    # basura), devolvemos nil: el caso de uso decide si registra el evento como informativo.
    def internal_status_for(external_status)
      return nil if external_status.nil?

      mapped = @service.response_value_mapper[external_status]
      mapped if Shipment::STATUSES.include?(mapped)
    end

    # Epoch en segundos si vino numérico o como string de sólo dígitos; Time.zone.parse para
    # cualquier otro string. Una fecha rota no debe tirar abajo el job: el caso de uso ya
    # tiene un fallback para occurred_at ausente.
    def parse_occurred_at(value)
      return nil if value.blank?
      return Time.zone.at(value.to_i) if epoch_seconds?(value)

      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def epoch_seconds?(value)
      value.is_a?(Numeric) || value.to_s.match?(/\A\d+\z/)
    end
  end
end
