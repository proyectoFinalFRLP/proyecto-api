# frozen_string_literal: true

# El transporte de una plantilla (Service): cómo se autentica, cómo viaja el
# request y cómo se lee la respuesta. Va aparte del modelo porque es un eje
# propio —se sumó de a poco: GraphQL y OAuth en TESIS-138, form, XML y `none` en
# TESIS-186 (ADR-022)— y el modelo ya cargaba con los roles de cada plantilla.
module ServiceTransport
  extend ActiveSupport::Concern

  # Cómo se autentica la plantilla (ver Integrations::AuthHeaders). `bearer` es
  # el comportamiento de siempre: `access_token` como Bearer y el resto de las
  # credenciales como headers literales.
  BEARER = 'bearer'
  OAUTH_CLIENT_CREDENTIALS = 'oauth_client_credentials'
  # Sin headers de autenticación: el proveedor recibe la cuenta como parámetros
  # del request (`credentials.<clave>` en el request_mapper, TESIS-186).
  NO_AUTH = 'none'
  AUTH_STRATEGIES = [BEARER, OAUTH_CLIENT_CREDENTIALS, NO_AUTH].freeze

  # Cómo viaja el body. GraphQL manda `{ query: body_template, variables }`,
  # donde las variables son el resultado del request_mapper. `form` manda el
  # resultado del request_mapper como `application/x-www-form-urlencoded`: en
  # el body de un POST o en el query string de un GET (TESIS-186, ADR-022).
  JSON_FORMAT = 'json'
  GRAPHQL_FORMAT = 'graphql'
  FORM_FORMAT = 'form'
  REQUEST_FORMATS = [JSON_FORMAT, GRAPHQL_FORMAT, FORM_FORMAT].freeze

  # Cómo se lee la respuesta. `xml` la convierte a un Hash
  # (Integrations::ParseXmlResponse) y desde ahí todo sigue igual: mappers,
  # `error_path`, dig_path.
  XML_FORMAT = 'xml'
  RESPONSE_FORMATS = [JSON_FORMAT, XML_FORMAT].freeze

  # Una fuente del request_mapper (o del body_template) que lee un secreto de
  # la cuenta: `credentials.usr` suelto o dentro de `{{credentials.usr}}`.
  CREDENTIALS_SOURCE = /(?:\A|\{\{\s*)credentials\./
  # Lo que manda el `body_template` como el valor de un parámetro.
  BODY_TEMPLATE_SOURCE = '{{template:body}}'
  # Los métodos que no llevan body: un form viaja en el query string.
  BODYLESS_METHODS = %w[GET DELETE].freeze

  included do
    validates :auth_strategy, inclusion: { in: AUTH_STRATEGIES }
    validates :request_format, inclusion: { in: REQUEST_FORMATS }
    validates :response_format, inclusion: { in: RESPONSE_FORMATS }
    validate :credentials_stay_out_of_the_query_string
  end

  def graphql? = request_format == GRAPHQL_FORMAT

  def form? = request_format == FORM_FORMAT

  def xml_response? = response_format == XML_FORMAT

  def no_auth? = auth_strategy == NO_AUTH

  def oauth_client_credentials? = auth_strategy == OAUTH_CLIENT_CREDENTIALS

  # Si el request viaja sin body: un form va entonces en el query string.
  def bodyless? = BODYLESS_METHODS.include?(http_method.to_s.upcase)

  private

  # Un form en un GET (o un DELETE) va en el query string, y con él los
  # `credentials.*` que mapee: la contraseña de la cuenta quedaría en la URL,
  # y una URL se guarda en los logs del proveedor, de los proxies y del
  # propio AdapterExecutionError. Se rechaza al guardar la plantilla, no en el
  # primer request: la que necesite mandar la cuenta como parámetro usa POST,
  # que la lleva en el body (TESIS-188).
  def credentials_stay_out_of_the_query_string
    return unless form? && bodyless? && sends_credentials_as_parameters?

    errors.add(:request_mapper, "manda credenciales en el query string de un #{http_method}: " \
                                'con request_format form, las credenciales sólo viajan por POST')
  end

  def sends_credentials_as_parameters?
    sources = request_mapper.is_a?(Hash) ? request_mapper.values.map(&:to_s) : []
    sources << body_template.to_s if sources.include?(BODY_TEMPLATE_SOURCE)
    sources.any? { |source| source.match?(CREDENTIALS_SOURCE) }
  end
end
