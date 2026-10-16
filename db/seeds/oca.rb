# frozen_string_literal: true

# OCA e-Pak como courier, enteramente con plantillas (TESIS-186, ADR-022).
#
# No hay una línea de Ruby que sepa de OCA: cotizar, despachar, pedir la
# etiqueta, seguir el envío y probar la conexión son plantillas del motor
# genérico. Lo que OCA tiene de particular —un servicio ASMX que recibe un form,
# contesta XML (DataSets de .NET) y pide el alta como un XML dentro de un
# parámetro— lo resuelven capacidades genéricas del adaptador: `request_format:
# form`, `response_format: xml`, `credentials.<clave>` y `{{template:body}}`.
#
# Apunta al entorno de PRUEBA de OCA (`ocadev`), nunca al productivo: es el que
# el equipo decidió usar (ADR-018).
#
# Sólo las plantillas: ninguna empresa queda conectada. La cuenta se carga con
# `bin/rails "integrations:oca:connect[norte]"` (lib/tasks/oca.rake), que lee
# `OCA_<SLUG>_*` del entorno o de `.env`, igual que las tareas de Shopify.
#
# Va aparte de `seeds.rb` para que el spec de punta a punta use exactamente
# estas plantillas (spec/integrations/oca_epak_spec.rb), y para que tocarlas no
# choque con el resto de los seeds.
#
# Métodos y no constantes: `seeds.rb` hace `load` de este archivo, y el spec de
# los seeds lo corre varias veces en el mismo proceso.
module OcaSeeds
  def self.base_uri
    'https://integraciones.ocadev.com.ar/epak_tracking_test/Oep_TrackEPak.asmx'
  end

  # Lo que comparten todas las plantillas: el transporte de un servicio ASMX.
  def self.transport
    { type: 'courier', http_method: 'POST', request_format: 'form', response_format: 'xml',
      auth_strategy: 'none', request_value_mapper: {}, response_value_mapper: {} }
  end

  def self.cuit_field
    { 'key' => 'cuit', 'label' => 'CUIT (con guiones)', 'required' => true,
      'format' => '\A\d{2}-\d{8}-\d\z' }
  end

  def self.operativa_field
    { 'key' => 'operativa', 'label' => 'Operativa (puerta a puerta)', 'required' => true,
      'format' => '\A\d+\z' }
  end

  # Cotización: `Tarifar_Envio_Corporativo`. Pide peso (kg), volumen (m³), los
  # dos códigos postales de 4 dígitos, el valor declarado, el CUIT y la
  # operativa. Todos son obligatorios para OCA (si falta uno contesta HTTP 500
  # «Missing parameter»): los que pueden no estar van con un `default`.
  def self.quote
    transport.merge(
      service_name: 'OCA e-Pak - Cotización',
      uri: "#{base_uri}/Tarifar_Envio_Corporativo",
      setting_fields: [cuit_field, operativa_field],
      request_mapper: {
        'PesoTotal' => '{{total_weight|default:0}}',
        'VolumenTotal' => '{{package_volume_m3|default:0}}',
        'CodigoPostalOrigen' => 'origin_postal_code',
        'CodigoPostalDestino' => 'destination_postal_code',
        'CantidadPaquetes' => 'literal:1',
        'ValorDeclarado' => '{{declared_value|default:0}}',
        'Cuit' => 'settings.cuit',
        'Operativa' => 'settings.operativa'
      },
      response_mapper: { 'Table.0.Total' => 'shipping_cost',
                         'Table.0.PlazoEntrega' => 'estimated_days' },
      # Un destino sin cobertura o una operativa inválida llegan con HTTP 200.
      error_path: 'Table1.0.Error'
    )
  end

  # El alta: `IngresoORMultiplesRetiros_v2`, con retiro confirmado. El envío
  # viaja como un XML dentro del parámetro `xml_Datos`, armado con el
  # body_template. Los largos máximos son los de OCA (calle 30, número 5,
  # localidad y provincia 30, nombre 30): si uno se pasa, rechaza el alta.
  #
  # Un solo bulto (el consolidado de TESIS-185) y puerta a puerta: es lo que
  # cubre la operativa de la demo.
  def self.dispatch
    transport.merge(
      service_name: 'OCA e-Pak',
      uri: "#{base_uri}/IngresoORMultiplesRetiros_v2",
      credential_fields: [
        { 'key' => 'usr', 'label' => 'Usuario e-Pak', 'required' => true },
        { 'key' => 'psw', 'label' => 'Contraseña e-Pak', 'required' => true }
      ],
      setting_fields: [
        cuit_field,
        { 'key' => 'nrocuenta', 'label' => 'Número de cuenta (######/###)', 'required' => true,
          'format' => '\A\d+/\d+\z' },
        operativa_field,
        { 'key' => 'centrocosto', 'label' => 'Centro de costo', 'required' => true,
          'format' => '\A\d+\z' },
        { 'key' => 'idfranjahoraria', 'label' => 'Franja horaria de retiro (1, 2 o 3)',
          'required' => false, 'format' => '\A[123]\z' },
        { 'key' => 'email', 'label' => 'Email de contacto del retiro', 'required' => false }
      ],
      request_mapper: {
        'usr' => 'credentials.usr',
        'psw' => 'credentials.psw',
        'xml_Datos' => '{{template:body}}',
        'ConfirmarRetiro' => 'literal:true',
        'ArchivoCliente' => 'literal:',
        'ArchivoProceso' => 'literal:',
        'compatMode' => 'literal:'
      },
      body_template: dispatch_xml,
      response_mapper: { 'DetalleIngresos.0.NumeroEnvio' => 'tracking_number',
                         'DetalleIngresos.0.OrdenRetiro' => 'external_reference' },
      # Una cuenta inválida llega como `Error`; un envío rechazado, en
      # `DetalleRechazos`. Los dos con HTTP 200.
      error_path: 'Error, DetalleRechazos.0.Motivo'
    )
  end

  def self.dispatch_xml
    <<~XML.squish.gsub('> <', '><')
      <?xml version="1.0" encoding="iso-8859-1" standalone="yes"?>
      <ROWS>
        <cabecera ver="2.0" nrocuenta="{{settings.nrocuenta}}"/>
        <origenes>
          <origen calle="{{origin_street|ascii|truncate:30}}"
                  nro="{{origin_street_number|default:S/N|truncate:5}}" piso="" depto=""
                  cp="{{origin_postal_code}}" localidad="{{origin_city|ascii|truncate:30}}"
                  provincia="{{origin_province|ascii|truncate:30}}" contacto=""
                  email="{{settings.email|truncate:100}}" solicitante="" observaciones=""
                  centrocosto="{{settings.centrocosto}}"
                  idfranjahoraria="{{settings.idfranjahoraria|default:1}}"
                  idcentroimposicionorigen="0" fecha="{{today|date:%Y%m%d}}">
            <envios>
              <envio idoperativa="{{settings.operativa}}" nroremito="OS-{{shipment_id}}">
                <destinatario apellido="{{customer_name|ascii|truncate:30}}" nombre=""
                              calle="{{destination_street|ascii|truncate:30}}"
                              nro="{{destination_street_number|default:S/N|truncate:5}}"
                              piso="" depto="" localidad="{{destination_city|ascii|truncate:30}}"
                              provincia="{{destination_province|ascii|truncate:30}}"
                              cp="{{destination_postal_code}}" telefono="" email="" idci="0"
                              celular="" observaciones=""/>
                <paquetes>
                  <paquete alto="{{package_height_cm|default:1}}"
                           ancho="{{package_width_cm|default:1}}"
                           largo="{{package_length_cm|default:1}}"
                           peso="{{total_weight|default:0}}"
                           valor="{{declared_value|default:0}}" cant="1"/>
                </paquetes>
              </envio>
            </envios>
          </origen>
        </origenes>
      </ROWS>
    XML
  end

  # La etiqueta: `GetPdfDeEtiquetasPorOrdenOrNumeroEnvio` contesta el PDF en
  # base64 dentro de un `<string>`. Si no la encuentra, contesta un texto en el
  # mismo lugar (Shipments::FetchLabel lo distingue).
  def self.label
    transport.merge(
      service_name: 'OCA e-Pak - Etiqueta', parent_service_name: 'OCA e-Pak', operation: 'label',
      uri: "#{base_uri}/GetPdfDeEtiquetasPorOrdenOrNumeroEnvio",
      request_mapper: { 'idOrdenRetiro' => 'external_reference', 'nroEnvio' => 'tracking_number',
                        'logisticaInversa' => 'literal:false' },
      response_mapper: { 'string' => 'label_pdf' }
    )
  end

  # «Probar conexión»: las operativas de la cuenta. Con un usuario o una
  # contraseña equivocados OCA contesta un DataSet vacío, que
  # Integrations::TestConnection toma como fallo. La primera operativa completa
  # el setting si la empresa no lo cargó.
  def self.connection_test
    transport.merge(
      service_name: 'OCA e-Pak - Conexión', parent_service_name: 'OCA e-Pak',
      operation: 'connection_test',
      uri: "#{base_uri}/GetOperativasByUsuario",
      request_mapper: { 'usr' => 'credentials.usr', 'psw' => 'credentials.psw' },
      response_mapper: { 'Table.0.IdOperativa' => 'operativa' }
    )
  end

  # Seguimiento: `GetEnvioEstadoActual`, el estado actual de un envío. OCA no
  # empuja webhooks: se le pregunta (ADR-014). La fecha viene sin hora
  # (`dd/MM/yyyy`) y el estado es un texto que a veces sigue con un detalle,
  # así que el mapper reconoce prefijos (`*`) sin distinguir mayúsculas ni
  # tildes.
  def self.tracking
    transport.merge(
      service_name: 'OCA e-Pak - Seguimiento',
      uri: "#{base_uri}/GetEnvioEstadoActual",
      request_mapper: { 'numeroEnvio' => 'tracking_number', 'ordenRetiro' => 'external_reference' },
      response_mapper: { 'Table.0.NumeroEnvio' => 'tracking_number',
                         'Table.0.Estado' => 'external_status',
                         'Table.0.FechaEstado' => 'occurred_at',
                         'Table.0.SucursalActual' => 'description' },
      response_value_mapper: tracking_statuses
    )
  end

  def self.tracking_statuses
    {
      'Envío Pendiente de Pago*' => 'ready_to_ship',
      'OR Pendiente*' => 'ready_to_ship',
      'En proceso de Retiro*' => 'ready_to_ship',
      'En proceso de Admision*' => 'ready_to_ship',
      'Retirado*' => 'in_transit',
      'Admitido*' => 'in_transit',
      'En Proceso en OCA*' => 'in_transit',
      'En viaje*' => 'in_transit',
      'En Transito*' => 'in_transit',
      'Arribado*' => 'in_transit',
      'Programado para visita*' => 'in_transit',
      'Visita*' => 'in_transit',
      'En Espera de Retiro por Sucursal*' => 'in_transit',
      'No entregado*' => 'in_transit',
      'Estado de Visita ONLINE*' => 'in_transit',
      'Entregado*' => 'delivered',
      'Estado de Visita ONLINE (Entregado)*' => 'delivered'
    }
  end

  def self.templates = [quote, dispatch, label, connection_test, tracking]

  # Crea o actualiza las plantillas y sus vínculos. Con el mismo criterio que
  # `seeds.rb`: en una plantilla que ya existe se reaplican los mappers y la
  # configuración de conexión, no la URI (puede haberse editado a mano).
  def self.install!
    templates.each do |attrs|
      attrs = attrs.except(:parent_service_name)
      service = Service.find_or_create_by!(service_name: attrs[:service_name]) do |s|
        s.assign_attributes(attrs)
      end
      service.update!(attrs.slice(*(Service::MAPPER_FIELDS + Service::CONNECTION_FIELDS)
                                     .map(&:to_sym)))
    end
    link!
  end

  def self.link!
    templates.select { |attrs| attrs[:parent_service_name] }.each do |attrs|
      Service.find_by!(service_name: attrs[:service_name])
             .update!(parent_service: Service.find_by!(service_name: attrs[:parent_service_name]))
    end
    Service.find_by!(service_name: dispatch[:service_name]).update!(
      quote_service: Service.find_by!(service_name: quote[:service_name]),
      tracking_service: Service.find_by!(service_name: tracking[:service_name])
    )
  end
end
