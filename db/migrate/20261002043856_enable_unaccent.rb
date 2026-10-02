# frozen_string_literal: true

# Búsqueda sin acentos en el catálogo y en las órdenes: "perez" tiene que
# encontrar "Pérez S.A.". `unaccent` es una extensión de contrib, incluida en la
# imagen oficial de Postgres y en las instalaciones de Homebrew.
class EnableUnaccent < ActiveRecord::Migration[8.1]
  def change
    enable_extension 'unaccent'
  end
end
