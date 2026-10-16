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

  included do
    validates :auth_strategy, inclusion: { in: AUTH_STRATEGIES }
    validates :request_format, inclusion: { in: REQUEST_FORMATS }
    validates :response_format, inclusion: { in: RESPONSE_FORMATS }
  end

  def graphql? = request_format == GRAPHQL_FORMAT

  def form? = request_format == FORM_FORMAT

  def xml_response? = response_format == XML_FORMAT

  def no_auth? = auth_strategy == NO_AUTH

  def oauth_client_credentials? = auth_strategy == OAUTH_CLIENT_CREDENTIALS
end
