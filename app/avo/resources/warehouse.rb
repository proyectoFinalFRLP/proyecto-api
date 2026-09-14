# frozen_string_literal: true

module Avo
  module Resources
    class Warehouse < Avo::BaseResource
      self.title = :name
      self.includes = [:company]

      def fields
        field :id, as: :id
        field :name, as: :text, required: true
        field :address, as: :text, required: true
        field :zip_code, as: :text, required: true
        field :company, as: :belongs_to

        field :stocks, as: :has_many, name: 'Inventory'
      end

      def filters
        filter Avo::Filters::CompanyFilter
      end
    end
  end
end
