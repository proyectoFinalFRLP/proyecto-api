class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  # El mayor valor de una columna `integer` de Postgres (int4). Una validación
  # numérica sin este tope deja pasar un número que la base rechaza al escribir,
  # y el error sale como 500 en vez de 422.
  MAX_INTEGER = 2_147_483_647
end
