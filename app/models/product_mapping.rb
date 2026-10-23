# frozen_string_literal: true

class ProductMapping < ApplicationRecord
  belongs_to :product
  belongs_to :company_integration

  validates :external_product_id, presence: true
  validates :company_integration_id, uniqueness: { scope: :product_id }
  # external_price es decimal(10,2): la DB tope en 99.999.999,99 y cualquier
  # valor mayor levanta ActiveRecord::RangeError, que Rails no mapea a ningún
  # status HTTP (o sea, 500). Con el rango explícito sale 422 y el límite queda
  # documentado. La misma línea tapa los otros dos agujeros del cast a
  # BigDecimal: 'abc' se guardaba como 0.0 en silencio y los negativos pasaban.
  validates :external_price, numericality: { greater_than_or_equal_to: 0, less_than: 100_000_000 },
                             allow_nil: true
  validate :product_and_integration_must_belong_to_same_company
  # Un vínculo que no puede publicar el stock no se crea, por ningún camino
  # (API, backoffice, consola): antes uno creado desde Avo quedaba sin
  # `inventory_item_id` y el sync fallaba en silencio (TESIS-177). Las
  # referencias que hacen falta las deduce la plantilla de stock del canal
  # (Catalog::StockPublishRequirements). Sólo se mira al crear o al cambiar el
  # canal o las referencias: un vínculo viejo incompleto se puede seguir
  # borrando o actualizando en lo demás.
  validate :carries_the_refs_to_publish_stock, if: :refs_check_needed?

  private

  def refs_check_needed?
    company_integration && (new_record? || will_save_change_to_external_refs? ||
                            will_save_change_to_company_integration_id?)
  end

  def carries_the_refs_to_publish_stock
    missing = Catalog::StockPublishRequirements.new(company_integration.service)
                                               .missing_refs(external_refs)
    return if missing.empty?

    errors.add(:external_refs, "must include #{missing.join(', ')} to publish stock in " \
                               "#{company_integration.service_name}: link the product from " \
                               'its sales channels, which looks them up')
  end

  def product_and_integration_must_belong_to_same_company
    return unless product && company_integration

    return unless product.company_id != company_integration.company_id
    errors.add(:base, 'product and integration must belong to the same company')
  end
end
