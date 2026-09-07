# frozen_string_literal: true

module Avo
  module Resources
    class Stock < Avo::BaseResource
      self.title = :display_name
      self.includes = %i[product warehouse]

      def fields
        field :id, as: :id
        field :product, as: :belongs_to
        field :warehouse, as: :belongs_to
        field :quantity, as: :number, required: true
      end
    end
  end
end
