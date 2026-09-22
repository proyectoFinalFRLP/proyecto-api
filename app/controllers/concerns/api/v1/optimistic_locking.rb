# frozen_string_literal: true

module Api
  module V1
    # Escrituras condicionadas por versión: el recurso sale con su versión en el
    # `ETag`, el cliente la devuelve en `If-Match` al guardar, y el servidor
    # rechaza la escritura con 412 si ya no es la vigente.
    #
    # Nació en el ABM de productos (TESIS-101) y se extrajo acá cuando la
    # modificación de órdenes (TESIS-126) necesitó el mismo contrato. Qué entra
    # en la versión lo decide cada recurso (Catalog::ProductVersion,
    # Orders::OrderVersion); acá sólo vive la parte de HTTP.
    module OptimisticLocking
      extend ActiveSupport::Concern

      private

      def expose_etag(version)
        response.set_header('ETag', %("#{version}"))
      end

      # `If-Match` puede venir con comillas, con el prefijo débil `W/` o como
      # `*`. `*` significa "cualquier versión, siempre que exista": el recurso ya
      # se resolvió antes de llegar acá, así que equivale a no poner precondición.
      def expected_version
        raw = request.headers['If-Match'].to_s.strip
        return nil if raw.blank? || raw == '*'

        raw.delete_prefix('W/').delete_prefix('"').delete_suffix('"')
      end

      # 412 y no 409: es el código que HTTP define para una precondición que no
      # se cumple, y los dos recursos que lo usan ya devuelven 409 por otras
      # razones (SKU duplicado y lock de stock ocupado en productos; envío
      # despachado en órdenes). Con 412 el front distingue el caso por el status,
      # sin leer el cuerpo.
      def render_precondition_failed(exception)
        render json: { error: exception.message, current_version: exception.current_version },
               status: :precondition_failed
      end
    end
  end
end
