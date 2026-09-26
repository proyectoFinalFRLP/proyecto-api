# frozen_string_literal: true

# Fila de GET /api/v1/integrations: una plantilla conectable con el estado de la
# integración de la empresa del token. Es lo que arma la pantalla de
# integraciones: qué proveedores hay, en qué estado está cada uno y qué datos
# pide el formulario de conexión (`credential_fields`, `setting_fields`).
#
# Ni la URI ni el método de la plantilla viajan (son detalles del motor), y de
# los secretos sólo se dice qué claves están cargadas, nunca sus valores.
class IntegrationStatusSerializer < ApplicationSerializer
  identifier :id, name: :service_id

  fields :service_name, :type, :auth_strategy, :credential_fields, :setting_fields

  field :configured do |service, options|
    options[:integrations_by_service_id].key?(service.id)
  end

  field :is_active do |service, options|
    integration = options[:integrations_by_service_id][service.id]
    integration ? integration.is_active : false
  end

  field :integration_id do |service, options|
    options[:integrations_by_service_id][service.id]&.id
  end

  # La configuración no secreta de la cuenta: el formulario la precarga.
  field :settings do |service, options|
    options[:integrations_by_service_id][service.id]&.settings || {}
  end

  # Qué secretos declarados tiene cargados la empresa. Sólo las claves.
  field :credentials_set do |service, options|
    credentials = options[:integrations_by_service_id][service.id]&.credentials || {}
    service.credential_fields.filter_map do |spec|
      spec['key'] if credentials[spec['key']].present?
    end
  end

  # Si «probar conexión» tiene algo que verificar (Integrations::TestConnection).
  field :testable do |service|
    service.declares_operation?(:connection_test) || service.oauth_client_credentials?
  end
end
