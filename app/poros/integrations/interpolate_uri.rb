# frozen_string_literal: true

module Integrations
  # Reemplaza los `:placeholders` de una URI de plantilla con valores. La usan
  # el adaptador (con los uri_params del caso de uso por encima de los settings
  # de la integración) y el pedido de token, cuya URL también depende de la
  # cuenta (`https://:shop_domain/admin/oauth/access_token`).
  class InterpolateUri < ApplicationPoro
    def initialize(template:, values:)
      super()
      @template = template.to_s
      @values = values.to_h.transform_keys(&:to_s)
    end

    # Las claves más largas primero: con `shop` y `shop_domain` cargadas, un
    # reemplazo de `:shop` antes que `:shop_domain` rompería el segundo.
    def call
      @values.keys.sort_by { |key| -key.length }.reduce(@template) do |uri, key|
        uri.gsub(":#{key}", @values[key].to_s)
      end
    end
  end
end
