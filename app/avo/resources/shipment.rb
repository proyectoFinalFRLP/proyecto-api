# frozen_string_literal: true

module Avo
  module Resources
    class Shipment < Avo::BaseResource
      self.title = :display_name
      self.includes = %i[company order shipment_events]

      def fields
        field :id, as: :id
        field :tracking_number, as: :text
        field :status, as: :select, options: ::Shipment::STATUSES.index_with(&:itself)
        field :shipping_cost, as: :number
        field :shipping_label_url, as: :text, only_on: :show
        field :company, as: :belongs_to
        field :order, as: :belongs_to
        field :company_integration, as: :belongs_to, name: 'Courier Integration'

        field :shipment_events, as: :has_many, name: 'Tracking Events'
      end

      def filters
        filter Avo::Filters::CompanyFilter
        filter Avo::Filters::ShipmentStatusFilter
      end
    end
  end
end
