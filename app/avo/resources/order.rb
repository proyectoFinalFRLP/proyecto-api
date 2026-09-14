# frozen_string_literal: true

module Avo
  module Resources
    class Order < Avo::BaseResource
      self.title = :display_name
      self.includes = %i[company company_integration order_items]

      def fields
        field :id, as: :id
        field :customer_name, as: :text, required: true
        field :customer_document, as: :text
        field :customer_address, as: :text
        field :customer_zip_code, as: :text
        field :external_order_id, as: :text
        field :status, as: :select, options: ::Order::STATUSES.index_with(&:itself)
        field :company, as: :belongs_to
        field :company_integration, as: :belongs_to, name: 'Integration'

        field :order_items, as: :has_many, name: 'Items'
        field :shipment, as: :has_one
      end

      def filters
        filter Avo::Filters::CompanyFilter
        filter Avo::Filters::OrderStatusFilter
      end
    end
  end
end
