# frozen_string_literal: true

class Service < ApplicationRecord
  self.inheritance_column = nil

  ECOMMERCE = 'ecommerce'
  COURIER = 'courier'
  TYPES = [ECOMMERCE, COURIER].freeze
  MAPPER_FIELDS = %w[request_mapper response_mapper request_value_mapper
                     response_value_mapper].freeze

  # Vocabulario de una plantilla de consulta de tracking (ver #answers_tracking?).
  TRACKING_STATUS_KEY = 'external_status'
  TRACKING_URI_PARAM = ':tracking_number'

  has_many :company_integrations, dependent: :restrict_with_error

  # Plantilla con la que se le pregunta a este courier por el estado de sus
  # envíos, para los proveedores que no empujan webhooks de tracking (TESIS-49,
  # ADR-014). Que esté cargada es lo que pone a sus envíos en la consulta
  # periódica; un courier que empuja el tracking (ADR-011) la deja vacía.
  belongs_to :tracking_service, class_name: 'Service', optional: true,
                                inverse_of: :tracked_services
  has_many :tracked_services, class_name: 'Service', foreign_key: :tracking_service_id,
                              inverse_of: :tracking_service, dependent: :nullify

  validates :service_name, presence: true, uniqueness: true
  validates :uri, presence: true
  validates :http_method, presence: true
  validates :type, presence: true, inclusion: { in: TYPES }
  validate :mappers_are_valid_json
  validate :tracking_service_answers_tracking

  # Sólo los canales de e-commerce generan ventas: el gateway lo usa para decidir
  # si un webhook entrante va al procesador de órdenes (TESIS-43) o queda a la
  # espera del de envíos (TESIS-24). CouriersController usa courier? con el mismo
  # criterio para decidir si encola el procesamiento de tracking (TESIS-48).
  def ecommerce? = type == ECOMMERCE

  def courier? = type == COURIER

  # Una plantilla de courier puede servir para cotizar o para despachar: son dos
  # endpoints distintos del mismo proveedor y, por convención del proyecto, dos
  # `Service` distintos (igual que 'Mercado Libre' y 'Mercado Libre - Stock').
  #
  # Cuál es cuál lo declara la propia plantilla en vez de una columna nueva: la
  # que sabe cotizar es la que mapea el costo en su `response_mapper`. Es el
  # mismo principio data-driven del resto de las integraciones — el template
  # dice qué sabe contestar — y evita una migración por cada capacidad nueva.
  def quotes_shipping?
    courier? && response_mapper.value?(Shipments::QuoteShipment::COST_KEY)
  end

  # La contracara de `quotes_shipping?`: la plantilla que sabe despachar es la
  # que declara de dónde leer el número de seguimiento de la respuesta
  # (TESIS-47). La de cotización no lo trae, y pedirle una etiqueta sería llamar
  # al endpoint de tarifas esperando otra cosa.
  #
  # Una plantilla de consulta de tracking (TESIS-49) también puede mapear el
  # número de seguimiento —para emparejar cada elemento de una respuesta masiva—
  # y no por eso sabe despachar: se excluye explícitamente.
  def dispatches_shipment?
    courier? && response_mapper.value?(Shipments::ConfirmDispatch::TRACKING_KEY) &&
      !answers_tracking?
  end

  # La plantilla sabe contestar por el estado de un envío si mapea el estado
  # externo Y dice cómo preguntar: interpolando un número de seguimiento en la
  # URI (una consulta por envío) o devolviendo una lista de envíos (consulta
  # masiva). La plantilla de despacho de un courier con push también mapea el
  # estado —para leer el webhook, ADR-011—, pero no cumple lo segundo.
  def answers_tracking?
    courier? && response_mapper.value?(TRACKING_STATUS_KEY) &&
      (uri.to_s.include?(TRACKING_URI_PARAM) || tracks_in_batch?)
  end

  # Consulta masiva: el número de seguimiento se lee de una colección (`[]`)
  # de la respuesta, uno por elemento, en vez de ser el de la URI.
  def tracks_in_batch?
    response_mapper.any? do |path, key|
      key == Shipments::ConfirmDispatch::TRACKING_KEY &&
        path.include?(Integrations::ParseExternalResponse::COLLECTION_MARKER)
    end
  end

  # Los mappers aceptan String JSON (formularios del backoffice) además de Hash:
  # un String se parsea y, si es inválido o no es un objeto, el registro queda
  # inválido y conserva el valor anterior.
  MAPPER_FIELDS.each do |mapper|
    define_method(:"#{mapper}=") do |value|
      super(coerce_mapper(mapper, value))
    end
  end

  private

  def coerce_mapper(field, value)
    mapper_errors.delete(field)
    return value unless value.is_a?(String)
    return {} if value.blank?

    parse_mapper(field, value)
  end

  def parse_mapper(field, value)
    parsed = JSON.parse(value)
    return parsed if parsed.is_a?(Hash)

    mapper_errors[field] = 'debe ser un objeto JSON (diccionario clave-valor)'
    self[field]
  rescue JSON::ParserError
    mapper_errors[field] = 'no es un JSON válido'
    self[field]
  end

  def mapper_errors
    @mapper_errors ||= {}
  end

  def mappers_are_valid_json
    mapper_errors.each { |field, message| errors.add(field, message) }
  end

  # Sólo un courier se consulta por tracking, y sólo con una plantilla que sepa
  # contestarlo: apuntar a la de cotización, o a sí misma, dejaría a la consulta
  # periódica llamando todos los ciclos a un endpoint que no responde estados.
  def tracking_service_answers_tracking
    reason = tracking_service_problem
    errors.add(:tracking_service, reason) if reason
  end

  def tracking_service_problem
    return if tracking_service.nil?
    return 'solo aplica a couriers' unless courier?
    return 'no puede ser la misma plantilla' if tracking_service == self

    'no es una plantilla de consulta de tracking' unless tracking_service.answers_tracking?
  end
end
