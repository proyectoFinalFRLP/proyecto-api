# frozen_string_literal: true

class ProductMappingPolicy < ApplicationPolicy
  def index?
    user.present?
  end

  def create?
    user.present?
  end

  def destroy?
    # product_mappings no tiene company_id: la tenencia se deriva del producto.
    # record.product puede ser nil si el producto quedó fuera del scope del
    # tenant activo (CompanyScoped filtra también las asociaciones); en ese caso
    # el mapping no es de este usuario y se niega el acceso.
    record.product&.company_id == user.company_id
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.joins(:product).where(products: { company_id: user.company_id })
    end
  end
end
