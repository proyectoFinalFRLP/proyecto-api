# frozen_string_literal: true

module Avo
  module Resources
    class Service < Avo::BaseResource
      self.title = :service_name
      self.includes = []

      def fields
        field :id, as: :id
        field :service_name, as: :text
        field :type, as: :select, options: ::Service::TYPES.index_with(&:itself)
        field :uri, as: :text
        field :http_method, as: :select, options: %w[GET POST PUT PATCH DELETE].index_with(&:itself)
        # Sólo para couriers sin webhooks de tracking: la plantilla con la que la
        # consulta periódica pregunta por sus envíos (TESIS-49).
        field :tracking_service, as: :belongs_to, use_resource: Avo::Resources::Service,
                                 name: 'Tracking template', only_on: %i[show forms]
        # En la plantilla que despacha: la que le pide tarifas al mismo
        # proveedor. Sin ella, el courier no se ofrece al cotizar (TESIS-131).
        field :quote_service, as: :belongs_to, use_resource: Avo::Resources::Service,
                              name: 'Quote template', only_on: %i[show forms]

        mapper_fields
      end

      private

      # Los diccionarios JSONB se editan como JSON y no se muestran en el index
      # para no saturar la tabla.
      def mapper_fields
        ::Service::MAPPER_FIELDS.each do |mapper|
          field mapper.to_sym, as: :code, language: 'javascript', only_on: %i[show forms],
                               format_using: lambda {
                                 value.is_a?(String) ? value : JSON.pretty_generate(value || {})
                               }
        end
      end
    end
  end
end
