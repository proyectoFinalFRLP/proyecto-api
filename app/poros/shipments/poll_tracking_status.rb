# frozen_string_literal: true

module Shipments
  # Le pregunta a un courier sin webhooks por el estado de sus envíos en curso y
  # registra en la bitácora lo que haya cambiado (TESIS-49, ADR-014). Es la
  # contracara de ProcessTrackingUpdate: allá el courier avisa, acá se le
  # pregunta; lo que se hace con cada movimiento es lo mismo
  # (RegisterTrackingEvent).
  #
  # La pregunta la contesta la plantilla de seguimiento del courier
  # (`Service#tracking_service`), con las credenciales de la integración que
  # despachó los envíos. Según lo que declare esa plantilla:
  #
  # - consulta individual: un request por envío, con el número en la URI;
  # - consulta masiva: un solo request con todos los números, y una respuesta
  #   que lista un elemento por envío.
  #
  # Ningún fallo sale de acá: un courier caído, una respuesta ilegible o un
  # movimiento que no se pudo guardar se registran en el log y el resto de la
  # consulta sigue. El próximo ciclo del cron es el reintento natural; reintentar
  # antes sólo acercaría al courier a su límite de requests.
  class PollTrackingStatus < ApplicationPoro
    LOG_TAG = '[TESIS-49]'

    # Claves internas con las que viajan los números de seguimiento. Van a la vez
    # como payload y como parámetro de URI: la plantilla toma la que mapea (un
    # GET sólo puede usar la URI; un POST masivo, el request_mapper).
    TRACKING_NUMBER_PARAM = 'tracking_number'
    TRACKING_NUMBERS_PARAM = 'tracking_numbers'

    MISSING_EXTERNAL_STATUS = 'the response does not carry an external status'

    def initialize(company_integration:, shipment_ids:)
      super()
      @integration = company_integration
      @shipment_ids = shipment_ids
    end

    # Devuelve los ShipmentEvent creados.
    def call
      return [] if tracking_service.nil? || shipments.empty?

      movements.filter_map { |shipment, translated| register(shipment, translated) }
    end

    private

    def tracking_service
      @tracking_service ||= @integration.service.tracking_service
    end

    # Se revalida al ejecutar, no al encolar: entre el barrido y este job el
    # envío pudo entregarse (por otro ciclo, o a mano desde el panel).
    # `order(:id)` no es cosmético: en la consulta masiva los números viajan
    # concatenados en la URI, así que sin un orden fijo el mismo lote produce
    # URLs distintas entre corridas. Postgres puede devolver las filas en
    # cualquier orden, y eso ya hacía fallar de forma intermitente al spec que
    # fija la URL del lote (TESIS-93).
    def shipments
      @shipments ||= @integration.shipments.in_flight.where(id: @shipment_ids).order(:id).to_a
    end

    # Pares [envío, movimiento traducido] a registrar.
    def movements
      return batch_movements if tracking_service.tracks_in_batch?

      shipments.filter_map { |shipment| single(shipment) }
    end

    def single(shipment)
      body = fetch(payload: { TRACKING_NUMBER_PARAM => shipment.tracking_number },
                   uri_params: { TRACKING_NUMBER_PARAM => shipment.tracking_number })
      return if body.nil?

      translated = TranslateTrackingPayload.new(service: tracking_service, payload: body).call
      [shipment, translated] if answers_for?(shipment, translated)
    end

    # Un solo request para todos los envíos; cada elemento de la respuesta se
    # empareja con su envío por número de seguimiento. Los elementos que no son
    # de ninguno de estos envíos se ignoran, igual que un push de un paquete
    # ajeno (ADR-011).
    def batch_movements
      numbers = shipments.map(&:tracking_number)
      body = fetch(payload: { TRACKING_NUMBERS_PARAM => numbers },
                   uri_params: { TRACKING_NUMBERS_PARAM => numbers.join(',') })
      return [] if body.nil?

      by_number = shipments.index_by(&:tracking_number)
      translate_elements(body).filter_map do |translated|
        shipment = matching_shipment(by_number, translated)
        [shipment, translated] if shipment && answers_for?(shipment, translated)
      end
    end

    # El envío de la consulta del que habla el elemento, o nil. Se descarta igual
    # que un push de un paquete ajeno, pero acá dejando rastro: la lista de
    # números la mandamos nosotros, así que un elemento que no es de ninguno es
    # un courier contestando por algo que no se le preguntó o, más probable, una
    # plantilla que no lee el número de cada elemento. Lo segundo se ve como
    # envíos que nunca avanzan, y sin esta línea no habría con qué diagnosticarlo.
    def matching_shipment(by_number, translated)
      reported = translated[:tracking_number]
      shipment = by_number[reported]
      return shipment if shipment

      Rails.logger.warn("#{LOG_TAG} #{tracking_service.service_name} batch element about " \
                        "#{reported.presence || 'no tracking number'} matches no shipment " \
                        'of the query')
      nil
    end

    def translate_elements(body)
      collection = Integrations::ParseExternalCollection.new(service: tracking_service,
                                                             payload: body)
      collection.source_elements.map do |element|
        TranslateTrackingPayload.new(service: tracking_service, payload: element,
                                     mapper: collection.element_mapper).call
      end
    end

    # nil si el courier no contestó: se loguea y la consulta sigue con el resto.
    def fetch(payload:, uri_params:)
      Integrations::HttpAdapter.new(company_integration: @integration, service: tracking_service,
                                    payload: payload, uri_params: uri_params).fetch
    rescue Integrations::AdapterExecutionError => e
      Rails.logger.warn("#{LOG_TAG} #{tracking_service.service_name} tracking query failed: " \
                        "#{e.message}")
      nil
    end

    # Sin estado externo no hay movimiento que registrar: es la plantilla que no
    # lo ubica en la respuesta. Y si la respuesta dice de qué paquete habla, tiene
    # que ser éste — un número distinto no se escribe en la bitácora de otro.
    def answers_for?(shipment, translated)
      reason = unusable_reason(shipment, translated)
      return true if reason.nil?

      Rails.logger.warn("#{LOG_TAG} #{tracking_service.service_name} " \
                        "shipment #{shipment.id}: #{reason}")
      false
    end

    def unusable_reason(shipment, translated)
      return MISSING_EXTERNAL_STATUS if translated[:external_status].blank?

      reported = translated[:tracking_number]
      return if reported.blank? || reported == shipment.tracking_number

      "the response is about tracking number #{reported}"
    end

    # Un movimiento que no se puede guardar no voltea a los demás envíos de la
    # misma consulta: se loguea como error —acá sí puede haber un bug— y se sigue.
    def register(shipment, translated)
      RegisterTrackingEvent.new(shipment: shipment, translated: translated).call
    rescue StandardError => e
      Rails.logger.error("#{LOG_TAG} could not register the tracking of shipment " \
                         "#{shipment.id}: #{e.class}: #{e.message}")
      nil
    end
  end
end
