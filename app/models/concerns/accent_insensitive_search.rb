# frozen_string_literal: true

# Búsqueda de texto que ignora mayúsculas **y acentos**: "perez" encuentra
# "Pérez S.A." y "PEREZ". ILIKE sólo pliega la caja; en Postgres `é` y `e` son
# caracteres distintos, así que hace falta `unaccent` de los dos lados.
#
# Vive en un solo lugar para que el catálogo y las órdenes busquen igual: antes
# las dos tenían su propio ILIKE, y cambiar uno solo los habría dejado con
# comportamientos distintos para el mismo operador.
#
# Sin índice, como antes: un `%term%` no usa un B-tree, y un índice GIN con
# `pg_trgm` sobre `unaccent(columna)` exige envolver `unaccent` en una función
# IMMUTABLE propia, que `schema.rb` no sabe volcar. Pedirlo implica pasar a
# `structure.sql`, que es una decisión del equipo. Con el volumen del MVP, el
# escaneo secuencial es instantáneo.
module AccentInsensitiveSearch
  extend ActiveSupport::Concern

  class_methods do
    # Filas donde alguna de `columns` contiene `term`. El término se escapa con
    # `sanitize_sql_like`: un `%` o un `_` tipeados se buscan literalmente.
    #
    # `columns` son nombres de columna del modelo, nunca datos del request: se
    # interpolan en el SQL, así que se validan contra `column_names`.
    def matching_text(columns, term)
      cleaned = term.to_s.strip
      return all if cleaned.blank?

      unknown = columns.map(&:to_s) - column_names
      raise ArgumentError, "unknown search columns: #{unknown.join(', ')}" if unknown.any?

      condition = columns.map { |column| "unaccent(#{table_name}.#{column}) ILIKE unaccent(:term)" }
      where(condition.join(' OR '), term: "%#{sanitize_sql_like(cleaned)}%")
    end
  end
end
