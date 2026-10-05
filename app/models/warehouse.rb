# frozen_string_literal: true

class Warehouse < ApplicationRecord
  include CompanyScoped

  belongs_to :company

  # Antes que el `restrict_with_error` de `stocks` (por eso `prepend`): las
  # filas en cero no son stock, son asignaciones vacías. Sin esto, un depósito
  # al que el modal de producto le «quitó» todos los productos —que viajan como
  # `quantity: 0`— no se podía borrar nunca, aunque no guardara nada.
  #
  # `delete_all` y no `destroy_all`: borrar una fila en cero no le cambia el
  # total a ningún producto, así que no hay nada que sincronizar con los canales
  # y el callback de `Stock` encolaría un job por producto para nada.
  #
  # Si otra cosa frena el borrado (ventas, transferencias), el `destroy` se
  # aborta dentro de su transacción y estas filas vuelven: no se pierde nada.
  before_destroy :release_empty_stock_rows, prepend: true

  # Bloquea el borrado si hay stock: las unidades son dato de negocio y no deben
  # evaporarse por un DELETE. destroy! levanta RecordNotDestroyed -> 409 (API).
  has_many :stocks, dependent: :restrict_with_error
  # Tampoco si salieron ventas de él (TESIS-126): la línea recuerda su depósito
  # para poder devolverle unidades al modificar la orden, y borrarlo dejaría esa
  # devolución sin destino. La FK es restrict por lo mismo; esto la adelanta a
  # un 409 legible en vez de un InvalidForeignKey.
  has_many :order_items, dependent: :restrict_with_error
  # Tampoco si una transferencia lo tiene como origen o como destino: la FK de
  # stock_transfers también es restrict, y sin esto el borrado llegaba a la base
  # y respondía 500. El caso real es el destino de una transferencia en
  # tránsito: todavía no tiene stock propio, porque las unidades se le suman
  # recién al recibirla.
  has_many :outgoing_transfers, class_name: 'StockTransfer', inverse_of: :origin_warehouse,
                                foreign_key: :origin_warehouse_id,
                                dependent: :restrict_with_error
  has_many :incoming_transfers, class_name: 'StockTransfer', inverse_of: :destination_warehouse,
                                foreign_key: :destination_warehouse_id,
                                dependent: :restrict_with_error

  validates :name, presence: true
  # Capacidad declarada del depósito, en unidades. Opcional: un depósito sin
  # capacidad cargada no es un error, es uno del que nadie declaró el techo
  # todavía, y la pantalla no dibuja su barra de ocupación. Mayor que cero
  # porque un depósito de capacidad cero no podría guardar nada.
  validates :capacity, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :zip_code, presence: true
  validates :address, presence: true

  # Unidades guardadas en cada deposito, agregadas por la base en una sola
  # consulta (TESIS-127). Misma mecanica que Product.with_total_stock: el
  # listado la necesita para todas las filas, y sumarla por asociacion seria
  # una consulta por deposito.
  scope :with_stored_units, lambda {
    left_joins(:stocks)
      .group(:id)
      .select('warehouses.*', 'COALESCE(SUM(stocks.quantity), 0) AS stored_units')
  }

  # Cuantas unidades hay guardadas aca. Si la fila vino de `with_stored_units`,
  # el alias del SELECT ya trae el agregado y hay que leerlo con has_attribute?
  # porque este metodo tiene precedencia sobre el atributo. Si no vino del scope
  # —el detalle, o un deposito recien creado— se suma por asociacion.
  def stored_units
    has_attribute?(:stored_units) ? self[:stored_units].to_i : stocks.sum(:quantity)
  end

  private

  # `reset`: si la asociación ya estaba cargada, el `restrict_with_error` que
  # corre después miraría la lista vieja, con las filas que ya no existen.
  def release_empty_stock_rows
    stocks.where(quantity: 0).delete_all
    stocks.reset
  end
end
