# frozen_string_literal: true

# Config pública del tenant: la consume el frontend antes de que haya sesión,
# así que no expone el id de la company ni ningún dato interno.
class TenantConfigSerializer < ApplicationSerializer
  fields :slug, :name, :branding, :features
end
