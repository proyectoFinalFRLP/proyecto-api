# frozen_string_literal: true

class ProductMappingSerializer < ApplicationSerializer
  identifier :id

  # `last_synced_at` es el último intento de publicar el stock en el canal y
  # `last_sync_error`, por qué falló (null si salió bien o si nunca se intentó).
  # Es lo que la tarjeta «Canales de venta» muestra junto a «Reintentar»
  # (TESIS-177).
  fields :product_id, :company_integration_id, :external_product_id,
         :last_synced_at, :last_sync_error, :created_at, :updated_at

  # El servicio viaja junto al mapping para que el front pueda mostrar
  # "Mercado Libre - ID: MLA123" sin pedir la integración en otra request.
  # El controller hace eager loading de company_integration y service.
  field :service_id do |mapping|
    mapping.company_integration.service_id
  end

  field :service_name do |mapping|
    mapping.company_integration.service.service_name
  end

  # external_price es decimal y BigDecimal se serializa como string por
  # defecto; exponerlo como número (o null) evita que el front tenga que parsear.
  field :external_price do |mapping|
    mapping.external_price&.to_f
  end
end
