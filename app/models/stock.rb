# frozen_string_literal: true

class Stock < ApplicationRecord
  belongs_to :product
  belongs_to :warehouse

  validates :quantity, numericality: { greater_than_or_equal_to: 0 }
  validates :warehouse_id, uniqueness: { scope: :product_id }
  validate :product_and_warehouse_must_belong_to_same_company

  # El disparo del sync saliente vive acá y no en el ABM porque la condición es
  # "cambió la tabla stocks", no "alguien usó tal endpoint": así queda cubierto
  # todo camino que escriba stock (ABM, descuento por venta, importaciones,
  # consola) sin depender de que cada uno se acuerde de encolar. El callback es
  # sólo el disparo; la lógica vive en el PORO Catalog::OutboundSync.
  after_commit :enqueue_outbound_sync, on: %i[create update destroy]

  private

  def product_and_warehouse_must_belong_to_same_company
    return unless product && warehouse

    return unless product.company_id != warehouse.company_id
    errors.add(:base, 'product and warehouse must belong to the same company')
  end

  def enqueue_outbound_sync
    return unless quantity_effectively_changed?

    # Este stock puede venir del borrado en cascada de su producto: sin
    # producto no queda nada que sincronizar (sus mappings se fueron con él) ni
    # de dónde sacar el tenant.
    return if product.nil? || product.destroyed?

    Catalog::SyncStockToChannelJob.perform_later(product_id, product.company_id)
  end

  # Un update que no movió la cantidad (sólo updated_at, por ejemplo) no le
  # cambia nada a los canales: no genera tráfico HTTP saliente.
  def quantity_effectively_changed?
    destroyed? || saved_change_to_quantity?
  end
end
