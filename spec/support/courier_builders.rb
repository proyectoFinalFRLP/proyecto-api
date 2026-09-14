# frozen_string_literal: true

# Alta de un operador logístico y de la integración de una empresa con él.
#
# Estaban copiados en los specs de órdenes y de envíos con formas apenas
# distintas —uno pasaba los mappers vacíos, el otro no; uno devolvía el Service y
# el otro la CompanyIntegration— y esa diferencia no significaba nada: los dos
# querían "un courier de esta empresa".
module CourierBuilders
  # `type: courier` es lo único que no se puede cambiar: un envío rechaza una
  # integración que no lo sea (ver Shipment#company_integration_is_a_courier).
  def courier_service(name = 'Andreani', **attrs)
    Service.create!({ service_name: name, type: Service::COURIER, http_method: 'POST',
                      uri: "https://#{name.downcase.tr(' ', '-')}.test/shipments" }.merge(attrs))
  end

  # `service:` para reusar uno ya creado; si no, lo crea con `name`. Una empresa
  # no puede tener dos integraciones contra el mismo servicio (índice único), así
  # que varios couriers de la misma empresa piden nombres distintos.
  def courier_integration(company:, name: 'Andreani', service: nil, **attrs)
    CompanyIntegration.create!(
      { company: company, service: service || courier_service(name) }.merge(attrs)
    )
  end
end

RSpec.configure { |config| config.include CourierBuilders }
