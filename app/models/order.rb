# frozen_string_literal: true

class Order < ApplicationRecord
  include CompanyScoped

  STATUSES = %w[pending paid cancelled].freeze

  # Las 24 jurisdicciones de la Argentina, con su nombre oficial: es el universo
  # del select de provincia del alta manual (TESIS-58). La provincia se valida
  # contra esta lista para poder agrupar por ella sin normalizar después; la
  # ciudad es texto libre porque no hay una lista confiable contra la cual
  # validarla (TESIS-128).
  PROVINCES = [
    'Buenos Aires', 'Catamarca', 'Chaco', 'Chubut', 'Ciudad Autónoma de Buenos Aires',
    'Córdoba', 'Corrientes', 'Entre Ríos', 'Formosa', 'Jujuy', 'La Pampa', 'La Rioja',
    'Mendoza', 'Misiones', 'Neuquén', 'Río Negro', 'Salta', 'San Juan', 'San Luis',
    'Santa Cruz', 'Santa Fe', 'Santiago del Estero', 'Tierra del Fuego', 'Tucumán'
  ].freeze

  belongs_to :company
  # OJO: `Order#company_integration` es el CANAL DE VENTA por el que entró la
  # orden (un ecommerce), no el operador logístico. `Shipment#company_integration`
  # se llama igual y significa lo contrario: el courier que la lleva. Son dos
  # integraciones distintas de la misma empresa, y el courier de una orden se
  # pide por `#courier`, que pasa por el envío.
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
  # allow_nil: las órdenes anteriores a TESIS-128 y las de webhook no la tienen.
  validates :customer_province, inclusion: { in: PROVINCES }, allow_nil: true
  validate :company_integration_belongs_to_company

  def display_name
    label = customer_name || "Order ##{id}"
    external_order_id ? "#{label} (#{external_order_id})" : label
  end

  # Lo que suman las líneas. Es el valor que los dos caminos de alta
  # (Orders::CreateOrder y Orders::ProcessWebhookOrder) escriben en
  # total_amount dentro de la misma transacción que crea la orden.
  #
  # Después no se recalcula: total_amount es el registro de lo que se facturó,
  # no una vista de lo que se facturaría con los precios de hoy (TESIS-114).
  def items_total
    order_items.sum { |item| item.quantity * item.unit_price }
  end

  # El courier que lleva la orden, para la columna «Operador logístico» del
  # listado (TESIS-52). Cuelga del envío y no de la orden, y las dos
  # asociaciones del camino son opcionales: una orden puede no tener envío
  # todavía, y el envío nace sin integración —se completa al confirmar el
  # despacho—. En cualquiera de los dos casos devuelve nil.
  #
  # Devuelve la integración y no su nombre: quién la serializa decide qué campos
  # expone, y así la orden no tiene que conocer la plantilla del Service.
  def courier
    shipment&.company_integration
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
