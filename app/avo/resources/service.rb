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
