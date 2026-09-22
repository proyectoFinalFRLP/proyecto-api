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

  # Unidades guardadas en cada deposito, agregadas por la base en una sola
  # consulta (TESIS-127). Misma mecanica que Product.with_total_stock: el
  # listado la necesita para todas las filas, y sumarla por asociacion seria
  # una consulta por deposito.
  scope :with_stored_units, lambda {
    left_joins(:stocks)
      .group(:id)
      .select('warehouses.*', 'COALESCE(SUM(stocks.quantity), 0) AS stored_units')
  }

  # Cuantas unidades hay guardadas aca. Si la fila vino de `with_stored_units`,
  # el alias del SELECT ya trae el agregado y hay que leerlo con has_attribute?
  # porque este metodo tiene precedencia sobre el atributo. Si no vino del scope
  # —el detalle, o un deposito recien creado— se suma por asociacion.
  def stored_units
    has_attribute?(:stored_units) ? self[:stored_units].to_i : stocks.sum(:quantity)
  end
end
