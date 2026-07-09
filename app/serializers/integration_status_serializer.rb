# frozen_string_literal: true

class IntegrationStatusSerializer < ApplicationSerializer
  identifier :id, name: :service_id

  fields :service_name, :type, :uri, :http_method

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
end
