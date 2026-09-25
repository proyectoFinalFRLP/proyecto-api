# frozen_string_literal: true

module Api
  module V1
    # Paginación de los listados de la API (TESIS-108).
    #
    # Existía copiada literal en cuatro controllers —el mismo `[page.to_i, 1].max`
    # y el mismo `clamp(1, 100)`— y ausente en otros cuatro, que devolvían la
    # tabla entera. Esto es la única definición de las dos cosas: cuántas filas
    # se devuelven y cómo se arma el `meta` que las acompaña.
    #
    # Todo listado de registros pasa por acá. Los vocabularios fijos
    # (`/orders/provinces`, `/products/categories`) y el resultado de una acción
    # (`/orders/:id/quotes`) no: su largo lo decide el código, no la empresa.
    #
    # La forma de la respuesta la fija ADR-015: la colección va en `data` y el
    # `meta` al lado, con `page`, `per_page` y `total`. El `total` cuenta el
    # scope **ya filtrado**, no la tabla: de ahí salen los contadores de las
    # pestañas y los KPIs del panel.
    module Paginatable
      extend ActiveSupport::Concern

      # Techo duro. Nadie puede pedir más, venga el número de donde venga: es lo
      # que impide que un listado devuelva una cantidad ilimitada de filas.
      MAX_PER_PAGE = 100

      # Cuántas filas devuelve un listado que nadie acotó. Es el tamaño de una
      # pantalla paginada.
      DEFAULT_PER_PAGE = 20

      # Para los listados que el consumidor lee enteros —depósitos, mapeos,
      # integraciones: los usa para llenar un select, no una tabla con
      # paginador—. Siguen teniendo techo; lo que cambia es que el default no
      # los recorta antes de tiempo.
      #
      # Si alguna empresa pasa de acá, el consumidor se entera por `meta.total`,
      # que va a ser mayor que las filas recibidas, y ahí le toca paginar. Es
      # preferible a que el default de 20 le esconda depósitos en silencio.
      WHOLE_LIST_PER_PAGE = MAX_PER_PAGE

      private

      # Devuelve `[filas, meta]`.
      #
      # `total:` se puede pasar cuando contar el scope no es directo: el catálogo
      # viene agrupado por `products.id`, así que su `.count` devuelve un Hash y
      # el controller ya sabe cómo contarlo (ver `count_of`).
      def paginate(scope, per_page: DEFAULT_PER_PAGE, total: nil)
        page = page_number
        size = page_size(per_page)

        [scope.offset((page - 1) * size).limit(size),
         { page: page, per_page: size, total: total || scope.count }]
      end

      # Página pedida, nunca menor que 1. `page=0` y `page=-3` se acotan en vez
      # de romper: un offset negativo es un error de SQL, y un 400 por un número
      # que se puede interpretar sería antipático.
      def page_number
        [scalar_param(:page).to_i, 1].max
      end

      # `scalar_param` y no `params[...]`: `?per_page[]=1` entrega un Array y
      # `Array#to_i` no existe (TESIS-124). Un valor no numérico cae en `to_i`
      # a 0 y el `clamp` lo lleva al mínimo.
      def page_size(default)
        (scalar_param(:per_page) || default).to_i.clamp(1, MAX_PER_PAGE)
      end
    end
  end
end
