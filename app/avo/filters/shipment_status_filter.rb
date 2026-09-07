# frozen_string_literal: true

class Avo::Filters::ShipmentStatusFilter < Avo::Filters::SelectFilter
  self.name = 'Status'

  def apply(request, query, value)
    return query if value.blank?

    query.where(status: value)
  end

  def options
    Shipment::STATUSES.index_with(&:itself)
  end
end
