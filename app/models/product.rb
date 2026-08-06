# frozen_string_literal: true

class Product < ApplicationRecord
  include CompanyScoped

  belongs_to :company
  has_many :stocks, dependent: :destroy
  has_many :product_mappings, dependent: :destroy
  # Bloquea el borrado si hay ítems de órdenes: son registros financieros y no
  # deben evaporarse por un DELETE. destroy! levanta RecordNotDestroyed -> 409 (API).
  has_many :order_items, dependent: :restrict_with_error

  validates :sku, presence: true, uniqueness: { scope: :company_id }
  validates :name, presence: true
  validates :weight, numericality: { greater_than_or_equal_to: 0 }

  scope :with_total_stock, lambda {
    left_joins(:stocks)
      .group(:id)
      .select('products.*', 'COALESCE(SUM(stocks.quantity), 0) AS total_stock')
  }

  # Retorna el stock total consolidado. Si la fila fue cargada con el scope
  # with_total_stock, el alias SQL `total_stock` ya trae el agregado calculado
  # por la DB: hay que leerlo con has_attribute? porque un método definido en
  # la clase tiene precedencia sobre el atributo del SELECT. Si la fila no
  # viene del scope, se suma por asociación (caso de detalle/creación).
  def total_stock
    has_attribute?(:total_stock) ? self[:total_stock].to_i : stocks.sum(:quantity)
  end
end
