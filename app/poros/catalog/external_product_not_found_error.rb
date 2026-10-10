# frozen_string_literal: true

module Catalog
  # El canal no tiene la publicación que se quiso vincular (o no se la puede
  # identificar sin ambigüedad). Es un dato inválido del usuario: 422.
  class ExternalProductNotFoundError < StandardError; end
end
