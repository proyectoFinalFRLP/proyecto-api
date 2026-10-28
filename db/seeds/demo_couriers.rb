# frozen_string_literal: true

# Los couriers de ejemplo de la demo pasan a OCA.
#
# Los seeds conectaban a Norte con Andreani y Correo Argentino con tokens
# inventados (DEMO-TOKEN-ANDREANI, DEMO-TOKEN-CORREO): nunca hablaron con el
# proveedor, pero la pantalla de integraciones las mostraba conectadas, la
# cotización les pedía tarifa y los envíos de ejemplo decían «Andreani» en
# Envíos y en Reportes. El único courier real de la demo es OCA, contra su
# entorno de prueba (ADR-022).
#
# Nada se borra: las integraciones de ejemplo quedan inactivas —como las de
# los canales de ejemplo, ver `seeds.rb`— y sus envíos pasan a la integración
# de OCA de la empresa. Las plantillas de Andreani y Correo Argentino siguen en
# el catálogo: son las que prueban el push de tracking (TESIS-48) y la consulta
# periódica (TESIS-49) sobre el motor genérico, y las usan sus specs. Sin una
# integración activa no se cotiza ni se despacha con ellas.
#
# Idempotente y pensado también para una base ya sembrada: los envíos que
# todavía digan `AND-` o lleven la etiqueta de apis.andreani.com se corrigen
# acá, porque `find_or_create_by!` no toca una fila que existe.
#
# Sin integración de OCA (los seeds sólo la conectan en desarrollo) las de
# ejemplo igual se desactivan, y los envíos quedan donde estaban hasta que se
# conecte OCA y se vuelva a correr esto: `bin/rails "demo:connect_oca[norte]"`
# lo hace en un entorno desplegado (lib/tasks/demo.rake).
#
# Métodos y no constantes, por lo mismo que OcaSeeds: `seeds.rb` hace `load`.
module DemoCouriers
  def self.fake_tokens = %w[DEMO-TOKEN-ANDREANI DEMO-TOKEN-CORREO]

  # El prefijo de los números que inventaban los seeds para Andreani, y el que
  # los reemplaza: OCA no los conoce, y `DEMO-` lo dice.
  def self.legacy_tracking = /\AAND-(\d+)\z/
  def self.demo_tracking_prefix = 'DEMO-OCA-'

  def self.retire!(company)
    fakes = fake_integrations(company)
    fakes.each { |integration| integration.update!(is_active: false) if integration.is_active? }

    Current.set(company_id: company.id) do
      oca = oca_integration(company)
      shipments = Shipment.where(company_integration_id: fakes.map(&:id))
                          .or(Shipment.where('shipping_label_url ILIKE ?', '%andreani%'))
                          .or(Shipment.where('tracking_number LIKE ?', 'AND-%'))
      shipments.find_each { |shipment| repoint(shipment, oca) }
    end
  end

  # Las credenciales van cifradas: no se pueden filtrar en SQL.
  def self.fake_integrations(company)
    CompanyIntegration.unscoped.where(company_id: company.id).select do |integration|
      credentials = integration.credentials
      credentials.is_a?(Hash) && fake_tokens.include?(credentials['access_token'])
    end
  end

  # La integración que despacha con OCA, si la empresa la tiene activa.
  def self.oca_integration(company)
    CompanyIntegration.unscoped.joins(:service)
                      .find_by(company_id: company.id, is_active: true,
                               services: { service_name: OcaSeeds.dispatch[:service_name] })
  end

  # `update_columns`: es una corrección de datos de ejemplo, no un movimiento
  # del envío. No tiene que cambiar `updated_at`, que la consulta periódica de
  # tracking usa para saber si el envío sigue vivo (Shipment.pollable).
  def self.repoint(shipment, oca)
    changes = {}
    changes[:company_integration_id] = oca.id if oca && shipment.company_integration_id != oca.id
    tracking = shipment.tracking_number.to_s[legacy_tracking, 1]
    changes[:tracking_number] = "#{demo_tracking_prefix}#{tracking}" if tracking
    changes[:shipping_label_url] = nil if shipment.shipping_label_url.to_s.include?('andreani')
    shipment.update_columns(changes) if changes.any? # rubocop:disable Rails/SkipsModelValidations
  end
end
