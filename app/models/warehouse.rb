# frozen_string_literal: true

class Warehouse < ApplicationRecord
  include CompanyScoped

  belongs_to :company
  # Bloquea el borrado si hay stock: las unidades son dato de negocio y no deben
  # evaporarse por un DELETE. destroy! levanta RecordNotDestroyed -> 409 (API).
  has_many :stocks, dependent: :restrict_with_error

  validates :name, presence: true
  validates :zip_code, presence: true
  validates :address, presence: true
end
