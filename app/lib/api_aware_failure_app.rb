# frozen_string_literal: true

# La API es stateless y responde 401 en JSON; el backoffice de /admin es
# navegacional y redirige al login. Devise decide por formato, no por ruta, así
# que el criterio se define acá según la ruta pedida.
#
# Warden reescribe PATH_INFO a /unauthenticated antes de invocar al failure app,
# por eso la ruta original se lee de attempted_path y no de request.path.
class ApiAwareFailureApp < Devise::FailureApp
  API_PREFIX = '/api'

  def respond
    return super unless api_request?

    self.status = :unauthorized
    self.content_type = 'application/json'
    self.response_body = { error: i18n_message }.to_json
  end

  private

  def api_request?
    attempted_path.to_s.start_with?(API_PREFIX)
  end
end
