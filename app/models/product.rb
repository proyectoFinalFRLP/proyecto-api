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

  # Hasta cuántas unidades un producto se considera en falta. Es un umbral único
  # y no un punto de reposición por producto: el modelo no tiene esa columna y
  # agregarla es una decisión de negocio propia, no un detalle de esta pantalla.
  #
  # Vive acá y no en el front porque de este número dependen dos cosas que
  # tienen que coincidir: el filtro del listado y el color del badge de cada
  # fila. Con el umbral del lado del cliente, pedir «stock bajo» y contar las
  # filas amarillas podían dar distinto.
  LOW_STOCK_THRESHOLD = 100

  # Los tres estados de disponibilidad, en el vocabulario de la pantalla.
  STOCK_STATUSES = %w[out_of_stock low available].freeze

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

  # Filtro por disponibilidad, para las pestañas del catálogo.
  #
  # Va con HAVING y no con WHERE porque el criterio es sobre el agregado: el
  # stock total de un producto es la suma de sus filas de `stocks`, y un WHERE
  # se evalúa antes de agrupar. Encadena sobre `with_total_stock`, que es quien
  # arma ese GROUP BY.
  #
  # Un estado desconocido no rompe: devuelve el scope sin tocar, mismo criterio
  # que el resto de los listados.
  # El umbral viaja como parámetro y no interpolado: aunque sea una constante
  # nuestra, un HAVING armado con interpolación es indistinguible de uno armado
  # con un dato del request para cualquiera que lea —o audite— este archivo.
  scope :by_stock_status, lambda { |status|
    case status
    when 'out_of_stock' then having('COALESCE(SUM(stocks.quantity), 0) = 0')
    when 'low' then having('COALESCE(SUM(stocks.quantity), 0) BETWEEN 1 AND ?',
                           LOW_STOCK_THRESHOLD)
    when 'available' then having('COALESCE(SUM(stocks.quantity), 0) > ?', LOW_STOCK_THRESHOLD)
    else all
    end
  }

  scope :by_category, ->(category) { category.present? ? where(category: category) : all }

  # Busca por las dos formas en que un operador nombra un producto: el código
  # con el que lo identifica y el nombre con el que lo conoce.
  scope :search_catalog, lambda { |term|
    cleaned = term.to_s.strip
    next all if cleaned.blank?

    pattern = "%#{sanitize_sql_like(cleaned)}%"
    where('sku ILIKE :pattern OR name ILIKE :pattern', pattern: pattern)
  }

  # Retorna el stock total consolidado. Si la fila fue cargada con el scope
  # with_total_stock, el alias SQL `total_stock` ya trae el agregado calculado
  # por la DB: hay que leerlo con has_attribute? porque un método definido en
  # la clase tiene precedencia sobre el atributo del SELECT. Si la fila no
  # viene del scope, se suma por asociación (caso de detalle/creación).
  def total_stock
    has_attribute?(:total_stock) ? self[:total_stock].to_i : stocks.sum(:quantity)
  end

  # Disponibilidad del producto, derivada del stock total. Es la misma regla que
  # usa `by_stock_status` para filtrar: si se calculara en el cliente, el filtro
  # y el color de la fila podrían discrepar.
  def stock_status
    total = total_stock
    return 'out_of_stock' if total.zero?

    total <= LOW_STOCK_THRESHOLD ? 'low' : 'available'
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
