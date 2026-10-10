# frozen_string_literal: true

class OrderItem < ApplicationRecord
  # Un envío en este estado todavía no salió, así que sus unidades siguen
  # físicamente en el depósito aunque ya estén vendidas. Una orden sin envío
  # —todavía no se abrió, o es un retiro en el local— está en la misma
  # situación, y por eso el filtro acepta también el NULL del LEFT JOIN.
  UNDISPATCHED_SHIPMENT_STATUSES = [nil, 'pending'].freeze

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
  # Las líneas vendidas que todavía están en el estante: lo «comprometido».
  #
  # Es la única definición del concepto en el sistema. La usan `Product`, para
  # el desglose del detalle, y `Warehouse.with_stored_units`, para la ocupación
  # del depósito. Con una copia en cada modelo bastaría con que alguien tocara
  # una para que la barra del panel y el detalle del producto dijeran cosas
  # distintas del mismo depósito (TESIS-170).
  #
  # Qué queda afuera y por qué:
  #
  # * Las órdenes canceladas, porque ya no están vendidas.
  # * Los retiros en el local (`requires_shipping: false`): la venta de mostrador
  #   se registra y se entrega en el mismo momento (TESIS-162), así que esas
  #   unidades ya salieron del estante.
  # * Los envíos despachados, que son los que el courier ya se llevó.
  #
  # Las líneas anteriores a TESIS-126 quedan afuera porque no registran de qué
  # depósito salieron: no se pueden atribuir a ninguno, y contarlas en el total
  # pero en ningún depósito dejaría una pantalla cuyas filas no suman el
  # encabezado.
  #
  # Se filtran por `warehouse_id` y no con un `joins(:warehouse)`, que haría lo
  # mismo: la FK garantiza que el depósito existe, y sumar `warehouses` al FROM
  # rompe a quien use este scope como subconsulta correlacionada contra esa
  # misma tabla —el nombre de adentro tapa al de afuera y la correlación se
  # pierde sin que nada falle—. Es lo que hace `Warehouse.with_stored_units`.
  # Quien necesite columnas del depósito agrega el join, como
  # `Product#committed_by_warehouse`.
  scope :committed, lambda {
    joins(:order)
      .left_outer_joins(order: :shipment)
      .where.not(order_items: { warehouse_id: nil })
      .where.not(orders: { status: Order::CANCELLED })
      .where(orders: { requires_shipping: true })
      .where(shipments: { status: UNDISPATCHED_SHIPMENT_STATUSES })
  }

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
