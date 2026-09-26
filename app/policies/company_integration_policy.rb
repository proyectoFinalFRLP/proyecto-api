# frozen_string_literal: true

class CompanyIntegrationPolicy < ApplicationPolicy
  # El flag `integrations` de la empresa sólo lo aplicaba el front: una empresa
  # sin la feature configuraba integraciones llamando al endpoint directo (QA de
  # TESIS-82). Se compara con `== true` en Company#feature_enabled?, igual que
  # el front, así los dos deciden lo mismo.
  def update?
    user.present? && user.company.feature_enabled?(:integrations)
  end
end
