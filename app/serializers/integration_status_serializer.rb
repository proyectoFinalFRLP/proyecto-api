# frozen_string_literal: true

# Fila de GET /api/v1/integrations: una plantilla conectable con el estado de la
# integración de la empresa del token. Es lo que muestra la pantalla de
# integraciones, que es de sólo lectura: las credenciales las carga el equipo
# de OneStock desde el backoffice (ADR-018).
#
# Ni la URI ni el método de la plantilla viajan (son detalles del motor), ni
# nada de las credenciales.
class IntegrationStatusSerializer < ApplicationSerializer
  identifier :id, name: :service_id

  fields :service_name, :type

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

  # El nombre de la cuenta del proveedor, si «probar conexión» lo obtuvo (en
  # Shopify, el de la tienda). Dice a qué cuenta está conectada la empresa.
  field :account_name do |service, options|
    settings = options[:integrations_by_service_id][service.id]&.settings || {}
    settings[Integrations::TestConnection::ACCOUNT_NAME_KEY]
  end

  # Si la integración puede publicar el stock y cómo le fue (TESIS-177): sin
  # esto, una integración sin ubicación de stock se veía «conectada» mientras
  # cada publicación fallaba en un job. null si la empresa no la conectó o si
  # la plantilla no publica stock. Ver Catalog::StockSyncStatus.
  field :stock_sync do |service, options|
    integration = options[:integrations_by_service_id][service.id]
    integration && options[:stock_sync_by_integration_id][integration.id]
  end
end
