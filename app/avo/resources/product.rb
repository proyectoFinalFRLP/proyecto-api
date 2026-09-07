# frozen_string_literal: true

module Avo
  module Resources
    class Product < Avo::BaseResource
      self.title = :name
      self.includes = [:company, :stocks]
      self.search = {
        query: -> { query.where('name ILIKE ? OR sku ILIKE ?', "%#{search_term}%", "%#{search_term}%") }
      }

      def fields
        field :id, as: :id
        field :sku, as: :text, required: true
        field :name, as: :text, required: true
        field :description, as: :textarea, only_on: :show
        field :category, as: :select, options: ::Product::CATEGORIES.index_with(&:itself)
        field :weight, as: :number
        field :dimensions, as: :text
        field :company, as: :belongs_to

        field :stocks, as: :has_many
        field :product_mappings, as: :has_many, name: 'External Mappings'
      end

      def filters
        filter Avo::Filters::CompanyFilter
      end
    end
  end
end
