# frozen_string_literal: true

class Warehouse < ApplicationRecord
  include CompanyScoped

  belongs_to :company
  # Bloquea el borrado si hay stock: las unidades son dato de negocio y no deben
  # evaporarse por un DELETE. destroy! levanta RecordNotDestroyed -> 409 (API).
  has_many :stocks, dependent: :restrict_with_error
  # Tampoco si salieron ventas de él (TESIS-126): la línea recuerda su depósito
  # para poder devolverle unidades al modificar la orden, y borrarlo dejaría esa
  # devolución sin destino. La FK es restrict por lo mismo; esto la adelanta a
  # un 409 legible en vez de un InvalidForeignKey.
  has_many :order_items, dependent: :restrict_with_error

  validates :name, presence: true
  validates :zip_code, presence: true
  validates :address, presence: true
end
