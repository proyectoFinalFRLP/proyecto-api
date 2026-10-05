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

  # Un envío en este estado todavía no salió, así que sus unidades siguen
  # físicamente en el depósito aunque ya estén vendidas. Una orden sin envío
  # —todavía no se abrió, o es un retiro en el local— está en la misma
  # situación, y por eso el filtro acepta también el NULL del LEFT JOIN.
  UNDISPATCHED_SHIPMENT_STATUSES = [nil, 'pending'].freeze

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

  # `in_transit:` lo pide quien va a leerlo. Es una subconsulta correlacionada
  # —una por fila— y los contadores de las pestañas no la miran: pedirla ahí
  # era pagarla cuatro veces para descartarla.
  scope :with_total_stock, lambda { |in_transit: true|
    columnas = ['products.*', 'COALESCE(SUM(stocks.quantity), 0) AS total_stock']
    columnas << "(#{IN_TRANSIT_SUBQUERY}) AS in_transit_quantity" if in_transit

    left_joins(:stocks).group(:id).select(*columnas)
  }

  # Filtro por disponibilidad, para las pestañas del catálogo.
  #
  # Va con HAVING y no con WHERE porque el criterio es sobre el agregado: el
  # stock total de un producto es la suma de sus filas de `stocks`, y un WHERE
  # se evalúa antes de agrupar. Encadena sobre `with_total_stock`, que es quien
  # arma ese GROUP BY.
  #
  # Un estado desconocido no rompe: devuelve el scope sin tocar, o sea el
  # catalogo entero. OJO: no es el criterio del listado de ordenes, que con un
  # status desconocido hace `where` igual y devuelve cero filas. La diferencia
  # es deliberada: ahi el estado es una columna y el valor invalido simplemente
  # no matchea; aca el filtro es una vista derivada del stock, y un tab que no
  # existe no describe ningun subconjunto. Si se unifican, que sea en las dos
  # puntas y no cambiando esta sola.
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
    self.class.stock_status_for(total_stock)
  end

  # La regla de disponibilidad, en un solo lugar. La usan el producto (sobre su
  # total) y cada fila de `stocks` (sobre lo que guarda ese depósito): si cada
  # uno tuviera su copia, el badge del detalle y el del catálogo podían volver a
  # discrepar, que es justo el bug que motivó exponer el estado desde acá.
  #
  # Por depósito es una regla provisoria: usa el mismo umbral global porque el
  # modelo no tiene punto de reposición por depósito. Si aparece, cambia acá.
  def self.stock_status_for(quantity)
    return 'out_of_stock' if quantity.to_i <= 0

    quantity <= LOW_STOCK_THRESHOLD ? 'low' : 'available'
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

  # Unidades vendidas que todavía no salieron del depósito, por depósito.
  #
  # El stock se descuenta al **crear** la orden (`Catalog::DeductStock`) y el
  # despacho no vuelve a tocar `stocks`, así que estas unidades ya no figuran en
  # ninguna fila de stock pero siguen estando en el estante hasta que el courier
  # se las lleva. Son las que el detalle muestra como «Comprometido».
  #
  # Las líneas sin depósito (anteriores a TESIS-126) quedan afuera: no se pueden
  # atribuir a ninguno, y contarlas en el total pero en ningún depósito dejaría
  # una pantalla cuyas filas no suman el encabezado.
  def committed_by_warehouse
    @committed_by_warehouse ||= committed_scope
                                .group(:warehouse_id, 'warehouses.name')
                                .order(:warehouse_id)
                                .sum(:quantity)
                                .map do |(warehouse_id, name), quantity|
      { warehouse_id: warehouse_id, name: name, quantity: quantity.to_i }
    end
  end

  # Unidades en vuelo hacia cada depósito: lo que todavía no figura en ningún
  # número del destino. El saliente no va: ya está descontado del on hand del
  # origen al despachar, y mostrarlo en esa fila se leería como si siguiera ahí.
  #
  # Va aparte y no por fila de `stocks` porque el destino puede no tener fila
  # hasta que la transferencia se recibe (`AdjustWarehouseStock` la crea
  # recién entonces). Una sola query agregada para todo el producto; cada
  # transferencia tiene un único destino, así que la suma de todas las
  # entradas es exactamente `in_transit_quantity`.
  def in_transit_by_warehouse
    stock_transfers.in_flight
                   .joins(:destination_warehouse)
                   .group(:destination_warehouse_id, 'warehouses.name')
                   .order(:destination_warehouse_id)
                   .sum(:quantity)
                   .map do |(warehouse_id, name), quantity|
      { warehouse_id: warehouse_id, name: name, quantity: quantity.to_i }
    end
  end

  # Lo comprometido de todo el producto. Suma el desglose en vez de volver a la
  # base: es el mismo número por definición, y así no puede discrepar con las
  # filas que muestra la pantalla.
  def committed_quantity
    committed_by_warehouse.sum { |row| row[:quantity] }
  end

  # Lo que hay físicamente: lo que queda libre más lo vendido sin despachar.
  def on_hand_quantity = total_stock + committed_quantity

  # Lo que se puede prometer es lo que queda libre: lo vendido ya se descontó de
  # `stocks` al crear la orden, así que no hay que volver a restarlo.
  def available_to_promise = total_stock

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

  private

  # Las líneas que cuentan como comprometidas. El LEFT JOIN con `shipments` es
  # lo que deja entrar a las órdenes que todavía no tienen envío; un INNER las
  # dejaría afuera, que es justo el caso más común apenas entra una venta.
  #
  # **Los retiros en el local no cuentan.** Lo comprometido es lo vendido que
  # todavía está en el estante, y lo que lo saca de ahí es el despacho. Una
  # venta de retiro no tiene envío —`CreateShipment` lo rechaza— y `Order`
  # no tiene un estado «retirada», así que nada la cerraría nunca: quedaría
  # comprometida para siempre y el «En depósito» crecería con cada retiro.
  #
  # La decisión es tratar el mostrador como lo que es: registrar la venta y
  # entregarla son el mismo momento, el cliente está ahí. Las unidades salen
  # del estante al crear la orden, que es exactamente cuando `DeductStock` las
  # saca de `stocks`. Así los dos números dicen lo mismo y no hace falta un
  # estado nuevo.
  #
  # Lo que sí queda abierto es la cancelación: sus unidades vuelven al estante
  # pero nada las devuelve a `stocks`, así que no las cuenta ni este scope ni
  # `total_stock`. Eso lo cierra TESIS-999009, que es la card que repone el
  # stock al cancelar.
  def committed_scope
    order_items.joins(:order, :warehouse)
               .left_outer_joins(order: :shipment)
               .where.not(orders: { status: Order::CANCELLED })
               .where(orders: { requires_shipping: true })
               .where(shipments: { status: UNDISPATCHED_SHIPMENT_STATUSES })
  end
end
