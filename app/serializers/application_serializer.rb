# frozen_string_literal: true

class ApplicationSerializer < Blueprinter::Base
  # El courier, con una sola forma en toda la API.
  #
  # Lo exponen tres endpoints —el listado de envíos, el detalle de un envío y el
  # listado de órdenes—, y son el mismo dato: la integración de la empresa con
  # el operador logístico. Escrito a mano en cada serializer terminó en dos
  # contratos distintos para el mismo concepto (un objeto en envíos, un string
  # suelto en órdenes), que obliga al front a modelarlo dos veces.
  #
  # El bloque recibe el objeto que se está serializando y devuelve la
  # CompanyIntegration, o nil. `nil` es un estado legítimo y no un dato
  # faltante: el envío nace sin courier y se le asigna al confirmar el despacho.
  def self.courier_field(name, &resolver)
    field name do |object|
      # `resolver.call` y no `yield`: Blueprinter guarda este bloque y lo corre
      # al serializar, cuando `courier_field` ya retornó. Ahí `yield` levanta
      # LocalJumpError, así que Performance/RedundantBlockCall no aplica.
      # rubocop:disable-next Performance/RedundantBlockCall
      integration = resolver.call(object)
      next nil if integration.nil?

      { id: integration.id, service_id: integration.service_id,
        name: integration.service_name }
    end
  end
end
