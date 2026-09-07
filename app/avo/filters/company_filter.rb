# frozen_string_literal: true

class Avo::Filters::CompanyFilter < Avo::Filters::SelectFilter
  self.name = 'Company'

  def apply(request, query, value)
    return query if value.blank?

    query.where(company_id: value)
  end

  def options
    Company.order(:name).pluck(:id, :name).to_h.transform_keys(&:to_s)
  end
end
