# frozen_string_literal: true

# Unidades de un producto que salieron de un depósito y todavía no llegaron a
# otro. Existe para poder expresar algo que `stocks` no puede: mientras viajan,
# las unidades no están en ningún nodo.
#
# Por eso NO se cuentan en `Product#total_stock`. El catálogo las expone aparte
# (`in_transit_quantity`), que es lo que alimenta el tab "In Transit" y el
# "+N Incoming" de TESIS-62.
#
# No hay estado borrador a propósito: una transferencia creada y no despachada
# deja las unidades en el origen, así que no aporta a los números que este
# modelo existe para producir. Crear una transferencia ES despacharla.
class StockTransfer < ApplicationRecord
  include CompanyScoped

  STATUSES = { in_transit: 'in_transit', received: 'received', cancelled: 'cancelled' }.freeze

  belongs_to :company
  belongs_to :product
  belongs_to :origin_warehouse, class_name: 'Warehouse'
  belongs_to :destination_warehouse, class_name: 'Warehouse'

  # Mismo criterio que WebhookLog y FailedEvent: el enum da predicados y scopes,
  # y `validate: true` invalida un estado desconocido en vez de explotar al
  # asignarlo.
  enum :status, STATUSES, validate: true

  validates :quantity, numericality: { only_integer: true, greater_than: 0 }
  validate :warehouses_are_distinct
  validate :product_and_warehouses_belong_to_company

  # Unidades en vuelo por producto. Se usa como subconsulta agregada desde el
  # listado del catálogo: una sola query para toda la página, no una por fila.
  scope :in_flight, -> { where(status: STATUSES[:in_transit]) }

  private

  def warehouses_are_distinct
    return if origin_warehouse_id.blank? || destination_warehouse_id.blank?
    return if origin_warehouse_id != destination_warehouse_id

    errors.add(:destination_warehouse, 'must be different from the origin warehouse')
  end

  # El producto y los dos depósitos tienen que ser de la misma empresa que la
  # transferencia: evita mover unidades entre tenants. Mismo criterio que Stock.
  def product_and_warehouses_belong_to_company
    return if company_id.blank?

    { product: product, origin_warehouse: origin_warehouse,
      destination_warehouse: destination_warehouse }.each do |name, record|
      next if record.blank? || record.company_id == company_id

      errors.add(name, 'must belong to the same company as the transfer')
    end
  end
end
