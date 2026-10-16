# frozen_string_literal: true

module Shipments
  # La etiqueta de un envío despachado, para imprimirla (TESIS-186).
  #
  # Hay couriers que devuelven la URL del PDF al despachar (Andreani, en
  # `shipping_label_url`) y otros que la emiten aparte, con otra llamada: OCA
  # e-Pak la pide con la orden de retiro y el número de envío, y contesta el
  # PDF en base64. Lo segundo lo declara la plantilla de despacho con una hija
  # `label` (Service#template_for): no hay código por courier.
  #
  # Devuelve `{ pdf: <bytes> }` si la emitió el courier, o `{ url: <url> }` si
  # sólo hay la URL guardada.
  #
  # La plantilla `label` mapea el documento a `label_pdf` (base64). Lo que
  # llegue ahí y no sea un PDF es un error del courier, no una etiqueta.
  class FetchLabel < ApplicationPoro
    OPERATION = :label
    PDF_KEY = 'label_pdf'
    PDF_SIGNATURE = '%PDF'

    # Corre dentro del request: el usuario está esperando el PDF para
    # imprimirlo. Más corto que el del adaptador en background, pero no tanto
    # como el de la cotización: armar el PDF le toma a OCA ~1 s.
    TIMEOUTS = { open: 4, read: 8 }.freeze

    def initialize(shipment:)
      super()
      @shipment = shipment
    end

    def call
      template = label_template
      return pdf_from(template) if template
      return { url: @shipment.shipping_label_url } if @shipment.shipping_label_url.present?

      raise LabelUnavailableError
    end

    # Si el envío tiene una etiqueta que pedir. Es lo que el serializer expone
    # como `label_available`, y por eso no consulta al courier.
    def self.available?(shipment)
      return false if shipment.tracking_number.blank?

      shipment.shipping_label_url.present? ||
        shipment.company_integration&.service&.declares_operation?(OPERATION) || false
    end

    private

    def label_template
      raise LabelUnavailableError, 'the shipment was not dispatched yet' if
        @shipment.tracking_number.blank? || integration.nil?

      integration.service.template_for(OPERATION)
    end

    def integration = @shipment.company_integration

    def pdf_from(template)
      encoded = Integrations::HttpAdapter.new(
        company_integration: integration, service: template,
        payload: params, uri_params: params, timeouts: TIMEOUTS
      ).call[PDF_KEY]

      { pdf: decode!(encoded, template) }
    end

    def params
      { 'tracking_number' => @shipment.tracking_number,
        'external_reference' => @shipment.external_reference.to_s }
    end

    def decode!(encoded, template)
      pdf = Base64.strict_decode64(encoded.to_s.delete("\r\n "))
      return pdf if pdf.start_with?(PDF_SIGNATURE)

      raise LabelResponseError.new(service_name: template.service_name, detail: encoded)
    rescue ArgumentError
      raise LabelResponseError.new(service_name: template.service_name, detail: encoded)
    end
  end
end
