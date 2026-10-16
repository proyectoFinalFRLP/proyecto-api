# frozen_string_literal: true

module Api
  module V1
    # Orden por columna de los listados (TESIS-184): `?sort=<clave>&direction=asc|desc`.
    #
    # Lo resuelve la API y no el front porque los listados paginan acá: el front
    # sólo tiene la página que ve, y ordenarla ahí daría «el mayor de estas 20
    # filas», no el mayor del listado.
    #
    # Cada controller declara su lista blanca: qué claves acepta y a qué
    # expresión SQL corresponde cada una. El valor del request nunca llega al
    # SQL: sólo elige una entrada de esa lista, y la dirección sale de
    # DIRECTIONS. Una clave o una dirección desconocida no rompe: el listado
    # sale con su orden de siempre, el mismo criterio que `by_stock_status` con
    # un estado que no existe.
    #
    # Dos reglas valen para cualquier orden, el pedido y el de siempre:
    # - Se desempata por `id` en la misma dirección. Sin eso, dos filas con el
    #   mismo valor (el mismo estado, la misma fecha) pueden cambiar de lugar
    #   entre una página y la siguiente, y una fila aparece dos veces o ninguna.
    # - Los vacíos van al final en las dos direcciones (`NULLS LAST`): una orden
    #   sin courier o un envío sin cotizar no tienen que encabezar la lista.
    module Sortable
      extend ActiveSupport::Concern

      DIRECTIONS = %w[asc desc].freeze

      # El orden de una columna de estado: el del ciclo de vida, no el
      # alfabético. Los valores salen de las constantes de los modelos, nunca
      # del request.
      def self.lifecycle(column, statuses)
        values = statuses.map { |status| "'#{status}'" }.join(', ')
        "array_position(ARRAY[#{values}]::text[], #{column}::text)"
      end

      private

      # `sorts` es la lista blanca `{ 'clave' => 'expresión SQL' }` y `default`
      # el orden de siempre, en la forma que acepta `order`.
      #
      # Nodos de Arel y no un string armado: la expresión sale de la lista
      # blanca, la dirección de DIRECTIONS y nada del request se interpola.
      def sort_listing(scope, sorts, default:)
        expression = sort_expression(sorts)
        direction = DIRECTIONS.find { |known| known == scalar_param(:direction).to_s.downcase }
        return scope.order(default) if expression.nil? || direction.nil?

        scope.order(Arel.sql(expression).public_send(direction).nulls_last,
                    scope.arel_table[:id].public_send(direction))
      end

      def sort_expression(sorts)
        requested = scalar_param(:sort).to_s
        sorts.find { |key, _expression| key == requested }&.last
      end
    end
  end
end
