# frozen_string_literal: true

module Avo
  module Filters
    class CompanyFilter < Avo::Filters::SelectFilter
      self.name = 'Company'

      def apply(_request, query, value)
        return query if value.blank?

        query.where(company_id: value)
      end

      def options
        Company.order(:name).pluck(:id, :name).to_h.transform_keys(&:to_s)
      end
    end
  end
end
