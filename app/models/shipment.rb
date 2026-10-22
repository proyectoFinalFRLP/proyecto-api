# frozen_string_literal: true

class Shipment < ApplicationRecord
  include CompanyScoped

  # El orden es el del ciclo de vida: el envío sólo avanza en él
  # (Shipments::RegisterTrackingEvent) y el listado ordena por él. Los tres
  # últimos son finales y alternativos entre sí, no pasos sucesivos.
  STATUSES = %w[pending ready_to_ship in_transit delivered returned cancelled].freeze

  # Cómo termina un envío: entregado, devuelto al remitente, o anulado por el
  # courier (TESIS-188). Un envío en uno de estos ya no se mueve —ni siquiera
  # a otro final— y no se le vuelve a preguntar al courier. «Perdido» o
  # «siniestrado» es `cancelled`: el paquete no va a llegar ni a volver, y para
  # la operación es lo mismo que una anulación (el envío se cierra sin entrega).
  TERMINAL_STATUSES = %w[delivered returned cancelled].freeze

  # Envíos cuyo ciclo logístico está abierto del lado del courier: ya tienen
  # etiqueta y todavía no terminaron. Es el universo que recorre la consulta
  # periódica de tracking (TESIS-49): `pending` no tiene número de seguimiento
  # por el que preguntar y los finales (TERMINAL_STATUSES) no cambian más —
  # consultarlos sólo gastaría la cuota del proveedor.
  IN_FLIGHT_STATUSES = %w[ready_to_ship in_transit].freeze

  # Tope de la consulta periódica: un envío en curso cuyo último movimiento
  # tiene más de esto deja de consultarse. Es la red para lo que el mapper no
  # reconozca como final: un estado nuevo del courier, o un envío que el
  # courier dejó de informar. Ningún envío normal tarda un mes en moverse, y a
  # 48 consultas por día uno trabado gastaba ~1.400 requests por mes. Sigue
  # en curso para el operador: lo que se corta es sólo la consulta.
  POLLING_CUTOFF = 30.days

  # Tope de `shipping_cost`: la columna es decimal(10,2), así que lo más grande
  # que entra es 99.999.999,99. Validarlo en el modelo hace que un costo fuera de
  # rango sea un error de validación y no un RangeError de la base; el despacho
  # lo prueba contra esta regla antes de pedir la etiqueta (TESIS-131).
  MAX_SHIPPING_COST = 100_000_000

  belongs_to :company
  # La integración se asigna al inicializar el envío y puede no existir todavía
  # (se completa al confirmar el despacho con un courier).
  #
  # OJO: acá `company_integration` es el OPERADOR LOGÍSTICO. En `Order` el
  # atributo se llama igual y significa lo contrario: el canal de venta por el
  # que entró la orden.
  belongs_to :company_integration, optional: true
  belongs_to :order
  has_many :shipment_events, dependent: :destroy

  scope :in_flight, -> { where(status: IN_FLIGHT_STATUSES).where.not(tracking_number: nil) }

  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :shipping_cost, numericality: { greater_than_or_equal_to: 0,
                                            less_than: MAX_SHIPPING_COST }, allow_nil: true
  # Restricción 1 a 1 de la card: una orden no puede tener dos envíos. El índice
  # único sobre order_id (migración) es la garantía a nivel motor; la validación
  # del modelo da un mensaje de error limpio antes de llegar a la DB.
  validates :order_id, uniqueness: true

  # Los envíos en curso que la consulta periódica todavía pregunta: los que se
  # movieron en los últimos POLLING_CUTOFF (ver ahí). Se mide desde el último
  # evento de la bitácora —un estado repetido no escribe uno nuevo, así que es
  # el último cambio— o, sin eventos, desde el último cambio del envío.
  scope :pollable, lambda { |now = Time.current|
    in_flight.where(<<~SQL.squish, cutoff: now - POLLING_CUTOFF)
      COALESCE((SELECT MAX(shipment_events.occurred_at) FROM shipment_events
                WHERE shipment_events.shipment_id = shipments.id),
               shipments.updated_at) >= :cutoff
    SQL
  }

  def terminal? = TERMINAL_STATUSES.include?(status)

  def display_name
    tracking_number || "Shipment ##{id}"
  end

  validate :order_belongs_to_company
  validate :company_integration_belongs_to_company
  validate :company_integration_is_a_courier

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
