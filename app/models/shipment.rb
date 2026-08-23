# frozen_string_literal: true

class Shipment < ApplicationRecord
  include CompanyScoped

  STATUSES = %w[pending ready_to_ship in_transit delivered].freeze

  belongs_to :company
  # La integración se asigna al inicializar el envío y puede no existir todavía
  # (se completa al confirmar el despacho con un courier).
  belongs_to :company_integration, optional: true
  belongs_to :order
  has_many :shipment_events, dependent: :destroy

  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :shipping_cost, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  # Restricción 1 a 1 de la card: una orden no puede tener dos envíos. El índice
  # único sobre order_id (migración) es la garantía a nivel motor; la validación
  # del modelo da un mensaje de error limpio antes de llegar a la DB.
  validates :order_id, uniqueness: true
  validate :order_belongs_to_company
  validate :company_integration_belongs_to_company

  private

  # El envío tiene su propio company_id (multi-tenancy): el de la orden debe
  # coincidir, evitando asociar un envío de la empresa A a una orden de la B.
  def order_belongs_to_company
    return unless order && company_id
    return if order.company_id == company_id

    errors.add(:base, 'order must belong to the same company as the shipment')
  end

  def company_integration_belongs_to_company
    return if company_integration.blank? || company_id.blank?
    return if company_integration.company_id == company_id

    errors.add(:company_integration, 'must belong to the same company')
  end
end
