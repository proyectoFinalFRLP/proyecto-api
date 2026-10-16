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

    # Fechas a la argentina, `dd/MM/yyyy` con o sin hora (TESIS-186). Sin hora,
    # el courier dice el día y no el momento: viaja como `occurred_on` y no se
    # inventa una hora (ver RegisterTrackingEvent#day_precision_time).
    DAY_MONTH_YEAR = %r{\A(\d{1,2})/(\d{1,2})/(\d{4})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}))?)?\z}

    # `mapper` permite traducir con un mapper derivado en lugar del
    # response_mapper completo: el de cada elemento de una respuesta masiva de
    # tracking (TESIS-49), con las rutas relativas al elemento. Mismo criterio
    # que Integrations::ParseExternalResponse.
    def initialize(service:, payload:, mapper: nil)
      super()
      @service = service
      @payload = payload
      @mapper = mapper || service.response_mapper
    end

    def call
      # TRACKING_KEYS acota qué se lee: cualquier otra clave que traiga el response_mapper
      # del Service (pensado para otras plantillas, p.ej. de órdenes) se ignora acá.
      raw = TRACKING_KEYS.index_with { |key| raw_value_for(key) }

      occurred = parse_occurred(raw['occurred_at'])
      {
        tracking_number: raw['tracking_number']&.to_s,
        external_status: raw['external_status']&.to_s,
        internal_status: internal_status_for(raw['external_status']&.to_s),
        occurred_at: occurred.is_a?(Date) ? nil : occurred,
        occurred_on: occurred.is_a?(Date) ? occurred : nil,
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
    # alimenta esta clave interna. Las entradas de colección ([]) describen listas (ítems de
    # una orden, por ejemplo); un push de tracking es un evento suelto, no una lista, así que
    # se descartan al invertir.
    def external_path_for(internal_key)
      single_event_mapper.key(internal_key)
    end

    def single_event_mapper
      @single_event_mapper ||= @mapper.reject do |path, _internal_key|
        path.include?(Integrations::ParseExternalResponse::COLLECTION_MARKER)
      end
    end

    # internal_status se calcula aparte del resto de las claves: sólo vale si el estado
    # externo está mapeado en la plantilla Y el resultado es un estado que el OMS reconoce.
    # Si el courier manda un estado nuevo que la plantilla no contempla (o el mapper apunta a
    # basura), devolvemos nil: el caso de uso decide si registra el evento como informativo.
    #
    # La búsqueda en el mapper admite prefijos y no distingue mayúsculas ni
    # tildes (Integrations::TranslateResponseValue): OCA informa
    # `En proceso de Retiro - Suc: ...` y el mapper dice `En proceso de Retiro*`.
    def internal_status_for(external_status)
      return nil if external_status.nil?

      _found, mapped = Integrations::TranslateResponseValue.new(
        mapper: @service.response_value_mapper, value: external_status
      ).call
      mapped if Shipment::STATUSES.include?(mapped)
    end

    # Epoch en segundos si vino numérico o como string de sólo dígitos; Time.zone.parse para
    # cualquier otro string. Una fecha rota no debe tirar abajo el job: el caso de uso ya
    # tiene un fallback para occurred_at ausente.
    #
    # Un `dd/MM/yyyy` se lee explícito y no con Time.zone.parse, que lo
    # adivina; sin hora devuelve una Date.
    def parse_occurred(value)
      return nil if value.blank?
      return Time.zone.at(value.to_i) if epoch_seconds?(value)

      day_month_year(value.to_s.strip) || Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def day_month_year(text)
      match = text.match(DAY_MONTH_YEAR)
      return nil if match.nil?

      day, month, year, hour, minute, second = match.captures.map { |part| part&.to_i }
      return Date.new(year, month, day) if hour.nil?

      Time.zone.local(year, month, day, hour, minute, second || 0)
    end

    def epoch_seconds?(value)
      value.is_a?(Numeric) || value.to_s.match?(/\A\d+\z/)
    end
  end
end
