# frozen_string_literal: true

class Service < ApplicationRecord
  self.inheritance_column = nil

  ECOMMERCE = 'ecommerce'
  COURIER = 'courier'
  TYPES = [ECOMMERCE, COURIER].freeze
  MAPPER_FIELDS = %w[request_mapper response_mapper request_value_mapper
                     response_value_mapper].freeze

  # Cómo se autentica la plantilla (ver Integrations::AuthHeaders). `bearer` es
  # el comportamiento de siempre: `access_token` como Bearer y el resto de las
  # credenciales como headers literales.
  BEARER = 'bearer'
  OAUTH_CLIENT_CREDENTIALS = 'oauth_client_credentials'
  AUTH_STRATEGIES = [BEARER, OAUTH_CLIENT_CREDENTIALS].freeze

  # Cómo viaja el body. GraphQL manda `{ query: body_template, variables }`,
  # donde las variables son el resultado del request_mapper.
  JSON_FORMAT = 'json'
  GRAPHQL_FORMAT = 'graphql'
  REQUEST_FORMATS = [JSON_FORMAT, GRAPHQL_FORMAT].freeze

  # Lo que define cómo se conecta una plantilla, además de sus mappers. Los
  # seeds lo reaplican sobre las plantillas que ya existen.
  CONNECTION_FIELDS = %w[auth_strategy auth_config credential_fields setting_fields
                         request_format body_template error_path operation].freeze

  # La clave interna con la que el sync saliente manda la cantidad a publicar.
  STOCK_KEY = 'available_quantity'

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

  # Plantilla con la que se le piden tarifas a este courier (TESIS-131). Cuelga
  # de la plantilla que despacha, igual que la de seguimiento: es lo que permite
  # pasar de una opción cotizada a su despacho, porque la cotización la contesta
  # una plantilla y la etiqueta la emite otra.
  belongs_to :quote_service, class_name: 'Service', optional: true,
                             inverse_of: :quoted_services
  has_many :quoted_services, class_name: 'Service', foreign_key: :quote_service_id,
                             inverse_of: :quote_service, dependent: :nullify

  # Plantillas de operación: otra llamada al mismo proveedor con la misma
  # cuenta (probar la conexión, buscar una variante, registrar un webhook). Una
  # hija no es conectable: se ejecuta con la integración de su madre, igual que
  # la plantilla de seguimiento de un courier (ADR-014).
  belongs_to :parent_service, class_name: 'Service', optional: true,
                              inverse_of: :operation_services
  has_many :operation_services, class_name: 'Service', foreign_key: :parent_service_id,
                                inverse_of: :parent_service, dependent: :destroy

  # Sólo las madres se conectan: el listado de integraciones y el alta las usan.
  scope :connectable, -> { where(parent_service_id: nil) }

  validates :service_name, presence: true, uniqueness: true
  validates :uri, presence: true
  validates :http_method, presence: true
  validates :type, presence: true, inclusion: { in: TYPES }
  validates :auth_strategy, inclusion: { in: AUTH_STRATEGIES }
  validates :request_format, inclusion: { in: REQUEST_FORMATS }
  validates :operation, presence: true, uniqueness: { scope: :parent_service_id },
                        if: :parent_service_id
  validate :mappers_are_valid_json
  validate :field_specs_are_lists
  validate :tracking_service_answers_tracking
  validate :quote_service_quotes_shipping

  # Sólo los canales de e-commerce generan ventas: el gateway lo usa para decidir
  # si un webhook entrante va al procesador de órdenes (TESIS-43) o queda a la
  # espera del de envíos (TESIS-24). CouriersController usa courier? con el mismo
  # criterio para decidir si encola el procesamiento de tracking (TESIS-48).
  def ecommerce? = type == ECOMMERCE

  def courier? = type == COURIER

  def graphql? = request_format == GRAPHQL_FORMAT

  def oauth_client_credentials? = auth_strategy == OAUTH_CLIENT_CREDENTIALS

  # La plantilla hija que sabe hacer `operation` con la cuenta de esta
  # integración, o nil si el proveedor no la declara.
  def template_for(operation)
    operation_services.find_by(operation: operation.to_s)
  end

  # La plantilla que publica el stock de esta integración: la propia si mapea
  # la cantidad (Tiendanube, 'Mercado Libre - Stock', Shopify), o su hija
  # `stock`. Si no hay ninguna, el sync saliente no le manda nada: antes le
  # mandaba el stock a cualquier plantilla con productos vinculados, aunque
  # fuera la de órdenes y no supiera qué hacer con él.
  def stock_template
    return self if request_mapper.value?(STOCK_KEY)

    template_for(:stock)
  end

  # Si la plantilla dice qué datos le pide a la empresa. Las que no declaran
  # nada conservan el alta de siempre (ver Integrations::UpsertIntegration).
  def declares_fields?
    credential_fields.any? || setting_fields.any?
  end

  # Si tiene una hija para `operation`. Usa la asociación cargada: el listado
  # de integraciones la precarga para no hacer una consulta por plantilla.
  def declares_operation?(operation)
    operation_services.any? { |child| child.operation == operation.to_s }
  end

  # Las claves de configuración que la plantilla le pide a la empresa.
  def setting_keys
    setting_fields.filter_map { |field| field['key'] }
  end

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
  # Una plantilla de seguimiento (TESIS-49) también puede mapear el número de
  # seguimiento —para emparejar cada elemento de una respuesta masiva— y no por
  # eso sabe despachar: se excluye explícitamente (ver #tracking_template?).
  def dispatches_shipment?
    courier? && response_mapper.value?(Shipments::ConfirmDispatch::TRACKING_KEY) &&
      !tracking_template?
  end

  # Si es la plantilla de seguimiento de algún courier. Lo dice el vínculo
  # (`tracking_service_id`), no la forma del mapper: una plantilla de despacho
  # cuyo proveedor conteste una lista (`envios[].numero`) tiene la misma forma
  # que una de consulta masiva, y deducirlo de ahí la dejaba sin poder despachar.
  # El vínculo es además lo que el resto de la consulta periódica usa como
  # fuente de verdad; una segunda definición podría discrepar con él.
  def tracking_template?
    tracked_services.exists?
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

  # Cada campo declarado es un objeto con al menos su `key`: es lo que el
  # formulario de conexión usa para armar cada input.
  def field_specs_are_lists
    %i[credential_fields setting_fields].each do |attribute|
      specs = public_send(attribute)
      next if specs.is_a?(Array) && specs.all? { |spec| spec.is_a?(Hash) && spec['key'].present? }

      errors.add(attribute, 'debe ser una lista de campos con su key')
    end
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

  def quote_service_quotes_shipping
    reason = quote_service_problem
    errors.add(:quote_service, reason) if reason
  end

  # Las dos últimas reglas sostienen lo que la cotización asume: cada opción
  # cotizada se despacha con UNA integración (QuoteShipment#dispatchers indexa
  # por plantilla de cotización). Si dos plantillas de despacho compartieran el
  # cotizador, una de las dos desaparecía de las opciones sin aviso; y una
  # plantilla que no despacha con cotizador cargado es una configuración que no
  # hace nada. El índice único de `quote_service_id` lo respalda en la base.
  def quote_service_problem
    return if quote_service.nil?
    return 'solo aplica a couriers' unless courier?
    return 'no puede ser la misma plantilla' if quote_service == self
    return 'solo aplica a la plantilla con la que el courier despacha' unless dispatches_shipment?
    return 'no es una plantilla de cotización' unless quote_service.quotes_shipping?

    'ya es la plantilla de cotización de otro courier' if quote_service_taken?
  end

  def quote_service_taken?
    self.class.where(quote_service_id: quote_service_id).where.not(id: id).exists?
  end
end
