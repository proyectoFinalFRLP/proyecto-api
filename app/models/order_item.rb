# frozen_string_literal: true

class OrderItem < ApplicationRecord
  belongs_to :order
  belongs_to :product
  # El depósito del que salió la línea (TESIS-126). Optional porque las líneas
  # anteriores a esa card no lo registraron y no hay con qué completarlas: sin él,
  # una modificación que tenga que devolverle unidades no sabe a dónde.
  belongs_to :warehouse, optional: true

  # Entero: la columna es integer y guardaba `0.5` como 0 y `2.7` como 2. El
  # primero pasaba la validación (0,5 > 0) y reventaba después en DeductStock
  # con un 500; el segundo se truncaba sin aviso. Se valida antes de escribir,
  # así el alta y el webhook responden 422 con el motivo.
  validates :quantity, numericality: { only_integer: true, greater_than: 0 }
  validates :unit_price, numericality: { greater_than_or_equal_to: 0 }
  validate :product_belongs_to_same_company_as_order
  validate :warehouse_belongs_to_same_company_as_order

  private

  # order_items no tiene company_id (tenant heredado de la orden): hay que
  # validar explícitamente que el producto pertenezca a la misma empresa que
  # la orden (lección TESIS-32 — FKs heredadas contra la misma empresa).
  def product_belongs_to_same_company_as_order
    return unless order && product
    return if order.company_id == product.company_id

    errors.add(:base, 'product must belong to the same company as the order')
  end

  # Mismo criterio que el producto: order_items no tiene company_id, así que la
  # FK al depósito no alcanza para impedir que una línea apunte al de otra empresa.
  def warehouse_belongs_to_same_company_as_order
    return unless order && warehouse
    return if order.company_id == warehouse.company_id

    errors.add(:base, 'warehouse must belong to the same company as the order')
  end
end
