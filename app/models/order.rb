# frozen_string_literal: true

class Order < ApplicationRecord
  include CompanyScoped

  STATUSES = %w[pending paid cancelled].freeze

  belongs_to :company
  belongs_to :company_integration, optional: true
  has_many :order_items, dependent: :destroy
  # Restricción MVP 1 orden = 1 envío (TESIS-45), garantizada por el índice
  # único sobre order_id en shipments.
  has_one :shipment, dependent: :destroy

  validates :customer_name, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :external_order_id, uniqueness: { scope: :company_id }, allow_nil: true
  # allow_nil: las órdenes anteriores a TESIS-114 que no tienen líneas no tienen
  # con qué calcularlo, y la orden vive un instante sin total dentro de la
  # transacción que la crea.
  validates :total_amount, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validate :company_integration_belongs_to_company

  # Lo que suman las líneas. Es el valor que los dos caminos de alta
  # (Orders::CreateOrder y Orders::ProcessWebhookOrder) escriben en
  # total_amount dentro de la misma transacción que crea la orden.
  #
  # Después no se recalcula: total_amount es el registro de lo que se facturó,
  # no una vista de lo que se facturaría con los precios de hoy (TESIS-114).
  def items_total
    order_items.sum { |item| item.quantity * item.unit_price }
  end

  private

  # La integración debe pertenecer a la misma empresa que la orden: evita que
  # una orden quede vinculada a una integración de otro tenant.
  def company_integration_belongs_to_company
    return if company_integration.blank? || company_id.blank?
    return if company_integration.company_id == company_id

    errors.add(:company_integration, 'must belong to the same company')
  end
end
