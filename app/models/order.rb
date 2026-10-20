# frozen_string_literal: true

class Order < ApplicationRecord
  include CompanyScoped

  STATUSES = %w[pending paid cancelled].freeze

  # El estado final de una venta que no va a salir. Con nombre porque son varios
  # los lugares que lo preguntan —el alta del envío, el despacho, el cálculo de
  # lo comprometido, la edición y los reportes— y un literal repetido en cada
  # uno es un typo esperando.
  CANCELLED = 'cancelled'

  # Las 24 jurisdicciones de la Argentina, con el nombre con el que se muestran
  # en el select de provincia del alta manual (TESIS-58). No es una lista
  # citable como nombres oficiales: Tierra del Fuego, por ejemplo, se llama
  # «Tierra del Fuego, Antártida e Islas del Atlántico Sur».
  #
  # La provincia se valida contra esta lista para poder agrupar por ella sin
  # normalizar después; la ciudad es texto libre porque no hay una lista
  # confiable contra la cual validarla (TESIS-128). Se expone en
  # GET /api/v1/orders/provinces para que el front no la repita.
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

  # Un domicilio vacío es «sin domicilio», llegue como `nil` o como `""`
  # (TESIS-178). El alta manual de un retiro en el local manda en blanco los
  # campos que el operador no completó, y `""` no es `nil` para el `allow_nil`
  # de la provincia: la venta se rechazaba con 422 y la única salida era elegir
  # una provincia cualquiera. Normalizarlo acá lo resuelve para cualquier
  # cliente —el front, Avo, un canal futuro— y deja NULL en la base en vez de
  # texto vacío. Unos espacios sueltos tampoco son un domicilio.
  #
  # Lo mismo el contacto (TESIS-179): un canal puede mandar `"email": ""`, y un
  # texto vacío contaba como dato —el detalle mostraba la celda en blanco en
  # vez de «—» y escondía la nota de que la orden no registra contacto.
  normalizes :customer_address, :customer_city, :customer_province, :customer_zip_code,
             :customer_email, :customer_phone, with: ->(value) { value.strip.presence }

  validates :customer_name, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  # Único por canal y no por empresa: dos canales de la misma empresa pueden
  # usar el mismo id. Es el índice `index_orders_on_integration_and_external_order_id`.
  validates :external_order_id, uniqueness: { scope: :company_integration_id }, allow_nil: true
  # allow_nil: las órdenes anteriores a TESIS-114 que no tienen líneas no tienen
  # con qué calcularlo, y la orden vive un instante sin total dentro de la
  # transacción que la crea.
  validates :total_amount, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  # allow_nil: las órdenes anteriores a TESIS-128 y las de webhook no la tienen.
  validates :customer_province, inclusion: { in: PROVINCES }, allow_nil: true
  # `inclusion` y no `presence`: la columna es NOT NULL y el campo es editable
  # por la API (TESIS-162), así que un `null` llegaba a la base y reventaba con
  # NotNullViolation -> 500. `presence` tampoco serviría: `false` es un valor
  # válido y para `presence` es ausencia.
  #
  # Un texto cualquiera sigue entrando como `true`: el casteo a booleano lo
  # hace ActiveRecord **antes** de validar, así que desde acá no se distingue
  # de un `true` legítimo. Es el comportamiento de Rails en toda la API.
  validates :requires_shipping, inclusion: { in: [true, false] }
  validate :company_integration_belongs_to_company

  # El número que muestra la tienda (TESIS-180) y, si no lo hay, el id del canal.
  def display_name
    reference = external_order_number || external_order_id
    label = customer_name || "Order ##{id}"
    reference ? "#{label} (#{reference})" : label
  end

  # El id interno que nombra un término de búsqueda, o nil. Una venta cargada a
  # mano no tiene número del canal y la pantalla la muestra como `#42`, así que
  # el operador tipea «42» o «#42»: los dos buscadores (órdenes y envíos) la
  # tienen que encontrar.
  #
  # Hasta 18 dígitos: lo que entra en un `bigint` sin desbordar. Un número más
  # largo no es un id, y bindearlo haría que Postgres corte la consulta.
  def self.internal_id_in(term)
    digits = term.to_s.strip.delete_prefix('#')
    digits.match?(/\A\d{1,18}\z/) ? digits.to_i : nil
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
