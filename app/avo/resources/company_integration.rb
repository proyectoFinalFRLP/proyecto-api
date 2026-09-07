# frozen_string_literal: true

module Avo
  module Resources
    class CompanyIntegration < Avo::BaseResource
      self.title = :display_name
      self.includes = %i[company service]

      def fields
        field :id, as: :id
        field :company, as: :belongs_to
        field :service, as: :belongs_to
        field :is_active, as: :boolean
        field :credentials, as: :code, language: 'json', only_on: %i[show forms],
                            format_using: -> { JSON.pretty_generate(value || {}) }
        field :product_mappings, as: :has_many, name: 'Product Mappings'
      end

      def filters
        filter Avo::Filters::CompanyFilter
      end
    end
  end
end
