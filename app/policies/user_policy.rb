# frozen_string_literal: true

class UserPolicy < ApplicationPolicy
  # Sólo la propia identidad. Alcanza para /me, y deja escrito —para cuando
  # exista el ABM de usuarios— que leer a otro es un permiso que todavía nadie
  # concedió.
  def show?
    user.present? && record.id == user.id
  end
end
