# frozen_string_literal: true

module Avo
  module Filters
    class ShipmentStatusFilter < Avo::Filters::SelectFilter
      self.name = 'Status'

      def apply(_request, query, value)
        return query if value.blank?

        query.where(status: value)
      end

      def options
        Shipment::STATUSES.index_with(&:itself)
      end
    end
  end
end
