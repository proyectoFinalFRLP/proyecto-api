# frozen_string_literal: true

class Product < ApplicationRecord
  include CompanyScoped

  # Vocabulario de categorías del catálogo. Es taxonomía de negocio, no una
  # máquina de estados: por eso vive acá y no como CHECK constraint. Las columnas
  # con CHECK del esquema (orders.status, services.type, failed_events.status)
  # son estados que el sistema transiciona y donde el motor tiene que ser el
  # último garante; una categoría la elige el usuario y la lista va a crecer.
  # Sumar una categoría tiene que ser una línea acá, no una migración.
  CATEGORIES = %w[Electronics Machinery Cabling Power].freeze

  # Unidades en vuelo hacia/desde depósitos, como subconsulta escalar.
  #
  # Subconsulta y no un segundo left_joins: `with_total_stock` ya hace join con
  # `stocks` y agrupa por products.id. Sumar un join a `stock_transfers` daría
  # producto cartesiano entre las dos tablas hijas y el SUM de stocks quedaría
  # multiplicado por la cantidad de transferencias. Es una query igual —no N+1—
  # pero sin contaminar la agregación existente.
  IN_TRANSIT_SUBQUERY = <<~SQL.squish
    SELECT COALESCE(SUM(st.quantity), 0) FROM stock_transfers st
    WHERE st.product_id = products.id AND st.status = 'in_transit'
  SQL

  belongs_to :company
  has_many :stocks, dependent: :destroy
  # restrict_with_error: una transferencia en vuelo son unidades reales ya
  # descontadas del origen. Borrar el producto las haría desaparecer sin rastro.
  has_many :stock_transfers, dependent: :restrict_with_error
  has_many :product_mappings, dependent: :destroy
  # Bloquea el borrado si hay ítems de órdenes: son registros financieros y no
  # deben evaporarse por un DELETE. destroy! levanta RecordNotDestroyed -> 409 (API).
  has_many :order_items, dependent: :restrict_with_error

  validates :sku, presence: true, uniqueness: { scope: :company_id }
  validates :name, presence: true
  validates :weight, numericality: { greater_than_or_equal_to: 0 }
  # allow_nil: la categoría es opcional — los productos que ya existían no
  # tienen ninguna y no hay con qué inferirla.
  validates :category, inclusion: { in: CATEGORIES }, allow_nil: true

  scope :with_total_stock, lambda {
    left_joins(:stocks)
      .group(:id)
      .select('products.*', 'COALESCE(SUM(stocks.quantity), 0) AS total_stock',
              "(#{IN_TRANSIT_SUBQUERY}) AS in_transit_quantity")
  }

  # Retorna el stock total consolidado. Si la fila fue cargada con el scope
  # with_total_stock, el alias SQL `total_stock` ya trae el agregado calculado
  # por la DB: hay que leerlo con has_attribute? porque un método definido en
  # la clase tiene precedencia sobre el atributo del SELECT. Si la fila no
  # viene del scope, se suma por asociación (caso de detalle/creación).
  def total_stock
    has_attribute?(:total_stock) ? self[:total_stock].to_i : stocks.sum(:quantity)
  end

  # Unidades que salieron de un depósito y todavía no llegaron a otro. No están
  # en `total_stock` a propósito: no son stock disponible en ningún nodo.
  #
  # Misma mecánica que total_stock: si la fila vino del scope, el alias del
  # SELECT ya trae el agregado; si no, se suma por asociación (detalle, alta).
  def in_transit_quantity
    return self[:in_transit_quantity].to_i if has_attribute?(:in_transit_quantity)

    stock_transfers.in_flight.sum(:quantity)
  end

  # Depósito donde está el grueso de las unidades. Lo consume la columna
  # "Location Node" del listado, que muestra un nodo y no el desglose.
  #
  # Desempata por warehouse_id ascendente: sin ese criterio, dos depósitos con
  # la misma cantidad devolverían uno u otro según el orden que le convenga a
  # Postgres, y la columna cambiaría de valor entre dos refrescos sin que haya
  # pasado nada.
  #
  # Ordena en Ruby y no en SQL a propósito: quien llama ya precargó
  # `stocks: :warehouse` para el listado, así que esto no toca la base. Un
  # `order` acá dispararía una query por fila.
  def primary_stock
    stocks.reject { |stock| stock.quantity.zero? }
          .min_by { |stock| [-stock.quantity, stock.warehouse_id] }
  end
end
