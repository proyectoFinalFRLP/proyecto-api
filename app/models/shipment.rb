# frozen_string_literal: true

class Shipment < ApplicationRecord
  include CompanyScoped

  STATUSES = %w[pending ready_to_ship in_transit delivered].freeze

  # Envíos cuyo ciclo logístico está abierto del lado del courier: ya tienen
  # etiqueta y todavía no se entregaron. Es el universo que recorre la consulta
  # periódica de tracking (TESIS-49): `pending` no tiene número de seguimiento
  # por el que preguntar y `delivered` es final — consultarlo sólo gastaría la
  # cuota del proveedor.
  IN_FLIGHT_STATUSES = %w[ready_to_ship in_transit].freeze

  # Tope de `shipping_cost`: la columna es decimal(10,2), así que lo más grande
  # que entra es 99.999.999,99. Validarlo en el modelo hace que un costo fuera de
  # rango sea un error de validación y no un RangeError de la base; el despacho
  # lo prueba contra esta regla antes de pedir la etiqueta (TESIS-131).
  MAX_SHIPPING_COST = 100_000_000

  # En qué zona se cuenta el día de la fecha comprometida: la de la operación,
  # la misma con la que Reportes corta sus ventanas (Reports::Window). La app
  # corre en UTC, y a las 22 h de Argentina UTC ya está en el día siguiente: un
  # envío comprometido para hoy figuraría demorado tres horas antes de tiempo.
  PROMISE_ZONE = ActiveSupport::TimeZone['America/Argentina/Buenos_Aires']

  belongs_to :company
  # La integración se asigna al inicializar el envío y puede no existir todavía
  # (se completa al confirmar el despacho con un courier).
  #
  # OJO: acá `company_integration` es el OPERADOR LOGÍSTICO. En `Order` el
  # atributo se llama igual y significa lo contrario: el canal de venta por el
  # que entró la orden.
  belongs_to :company_integration, optional: true
  belongs_to :order
  # De qué depósito salió el paquete. Lo fija el despacho: antes no hay origen,
  # y los envíos despachados antes de guardarlo no lo tienen.
  belongs_to :origin_warehouse, class_name: 'Warehouse', optional: true,
                                inverse_of: :dispatched_shipments
  has_many :shipment_events, dependent: :destroy

  scope :in_flight, -> { where(status: IN_FLIGHT_STATUSES).where.not(tracking_number: nil) }

  # Envíos todavía en camino cuya fecha comprometida ya pasó. Es la anomalía de
  # Reportes y el filtro «demorados» del listado: una sola definición para que
  # los dos cuenten lo mismo. Sin fecha comprometida un envío no está demorado,
  # porque nadie le prometió un plazo.
  scope :delayed, lambda { |today = PROMISE_ZONE.today|
    where(status: IN_FLIGHT_STATUSES).where(promised_delivery_on: ...today)
  }

  def self.promise_for(estimated_days, from: Time.current)
    from.in_time_zone(PROMISE_ZONE).to_date + estimated_days
  end

  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :shipping_cost, numericality: { greater_than_or_equal_to: 0,
                                            less_than: MAX_SHIPPING_COST }, allow_nil: true
  # Restricción 1 a 1 de la card: una orden no puede tener dos envíos. El índice
  # único sobre order_id (migración) es la garantía a nivel motor; la validación
  # del modelo da un mensaje de error limpio antes de llegar a la DB.
  validates :order_id, uniqueness: true

  def display_name
    tracking_number || "Shipment ##{id}"
  end

  # La misma regla que el scope `delayed`, para una fila ya cargada.
  def delayed?(today = PROMISE_ZONE.today)
    IN_FLIGHT_STATUSES.include?(status) && promised_delivery_on.present? &&
      promised_delivery_on < today
  end

  validate :order_belongs_to_company
  validate :company_integration_belongs_to_company
  validate :company_integration_is_a_courier
  validate :origin_warehouse_belongs_to_company

  private

  def origin_warehouse_belongs_to_company
    return if origin_warehouse.blank? || company_id.blank?
    return if origin_warehouse.company_id == company_id

    errors.add(:origin_warehouse, 'must belong to the same company')
  end

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

  # Un envío sólo lo lleva un operador logístico. Nada lo impedía: el camino de
  # producción elige entre integraciones de tipo courier (Shipments::QuoteShipment
  # filtra por `services.type`), pero una asignación directa —el panel, un job
  # nuevo, un seed— podía colgarle un canal de ecommerce. El listado de órdenes
  # mostraría entonces «Tiendanube» en la columna del operador logístico: un
  # dato que se lee como cierto y no lo es.
  def company_integration_is_a_courier
    return if company_integration.blank?
    return if company_integration.service.courier?

    errors.add(:company_integration, 'must be a courier integration')
  end
end
