# frozen_string_literal: true

module Webhooks
  # Traduce la excepción de un FailedEvent a un código de soporte estable y a
  # una causa en castellano que un operador pueda leer (ADR-024). El texto
  # técnico (`last_error`) sigue guardándose para diagnosticar: el código es lo
  # que se le dicta a soporte y lo que sobrevive a un cambio de mensaje.
  #
  # Los códigos no se renumeran ni se reutilizan nunca: uno que deja de usarse
  # queda retirado, y una causa nueva lleva un número nuevo. Las filas ya
  # guardadas, los reportes y lo que el operador anotó siguen significando lo
  # mismo.
  module ErrorCatalog
    UNKNOWN = 'GEN-000'

    MESSAGES = {
      'GEN-000' => 'Error inesperado',
      'GEN-001' => 'El tipo de evento no se puede reprocesar',
      'INT-001' => 'Falló la comunicación con el proveedor',
      'INT-002' => 'El proveedor rechazó las credenciales de la conexión',
      'INT-003' => 'El proveedor no encontró lo que se le pidió',
      'INT-004' => 'El proveedor frenó los pedidos por exceso de uso',
      'INT-005' => 'El proveedor no está disponible',
      'INT-006' => 'El proveedor no respondió a tiempo',
      'INT-007' => 'No se pudo conectar con el proveedor',
      'INT-008' => 'El proveedor rechazó el pedido',
      'INT-009' => 'La respuesta del proveedor no se pudo leer',
      'INT-010' => 'Falta un dato que el proveedor exige',
      'INT-011' => 'La plantilla de la integración tiene un error',
      'INT-012' => 'Los datos de la conexión no son válidos',
      'INT-013' => 'La conexión está inactiva o fue eliminada',
      'INT-014' => 'La firma del aviso del proveedor no es válida',
      'ORD-001' => 'La venta llegó con datos incompletos',
      'ORD-002' => 'La venta trae un producto sin vincular',
      'ORD-003' => 'El aviso original de la venta ya no existe',
      'TRK-001' => 'El seguimiento llegó con datos incompletos',
      'TRK-002' => 'El aviso original del seguimiento ya no existe',
      'STK-001' => 'No hay stock suficiente para la venta',
      'STK-002' => 'Otra operación estaba usando el stock del producto',
      'STK-003' => 'Al canal le falta configuración para publicar stock',
      'STK-004' => 'La publicación no existe en el canal',
      'STK-005' => 'No hay stock suficiente en el depósito'
    }.freeze

    # Por nombre y no por clase: así el catálogo no obliga a cargar cada PORO
    # para resolverse, y la migración que completó las filas viejas pudo
    # comparar contra el texto guardado en `last_error`.
    BY_CLASS = {
      'Webhooks::ReplayRegistry::UnknownEventType' => 'GEN-001',
      'Integrations::AdapterExecutionError' => 'INT-001',
      'Integrations::ParseXmlResponse::MalformedXmlError' => 'INT-009',
      'Integrations::MissingValueError' => 'INT-010',
      'Integrations::RenderTemplate::MissingValueError' => 'INT-010',
      'Integrations::RenderTemplate::Error' => 'INT-011',
      'Integrations::RenderTemplate::UnknownFilterError' => 'INT-011',
      'Integrations::InvalidIntegrationError' => 'INT-012',
      'Webhooks::Replayers::HttpRequest::MissingIntegration' => 'INT-013',
      'Webhooks::InvalidSignatureError' => 'INT-014',
      'Orders::ProcessWebhookOrder::InvalidPayloadError' => 'ORD-001',
      'Orders::ProcessWebhookOrder::UnmappedProductError' => 'ORD-002',
      'Webhooks::Replayers::OrderIngestion::MissingWebhookLog' => 'ORD-003',
      'Shipments::ProcessTrackingUpdate::InvalidPayloadError' => 'TRK-001',
      'Webhooks::Replayers::TrackingIngestion::MissingWebhookLog' => 'TRK-002',
      'Catalog::InsufficientStockError' => 'STK-001',
      'Catalog::LockTimeoutError' => 'STK-002',
      'Catalog::ChannelNotReadyError' => 'STK-003',
      'Catalog::ExternalProductNotFoundError' => 'STK-004',
      'Catalog::InsufficientWarehouseStockError' => 'STK-005'
    }.freeze

    module_function

    def code_for(error)
      return nil if error.nil?
      return adapter_code(error) if error.is_a?(Integrations::AdapterExecutionError)

      code_by_class(error) || UNKNOWN
    end

    # Un código que este catálogo no conoce (uno retirado, o una fila escrita a
    # mano) se lee como error inesperado y no deja la causa en blanco.
    def message_for(code)
      return nil if code.nil?

      MESSAGES.fetch(code) { MESSAGES.fetch(UNKNOWN) }
    end

    # Todo lo que sale del HttpAdapter es AdapterExecutionError: la clase sola
    # no dice nada. Lo que distingue un fallo de otro es el status con el que
    # contestó el proveedor y, si no contestó, la excepción original que el
    # adapter envolvió (`cause`, que Ruby completa al levantar dentro de un
    # rescue).
    def adapter_code(error)
      return 'INT-010' if error.is_a?(Integrations::MissingValueError)

      status_code(error.response_status) || cause_code(error.cause) ||
        (error.rejected? ? 'INT-008' : 'INT-001')
    end

    def status_code(status)
      case status
      when 401, 403 then 'INT-002'
      when 404 then 'INT-003'
      when 429 then 'INT-004'
      when 500..599 then 'INT-005'
      when 400..499 then 'INT-008'
      end
    end

    # El timeout va antes que el resto de la red: Net::OpenTimeout y
    # Net::ReadTimeout también están en NETWORK_ERRORS.
    def cause_code(cause)
      case cause
      when Timeout::Error then 'INT-006'
      when *Integrations::HttpAdapter::NETWORK_ERRORS then 'INT-007'
      when JSON::ParserError, Integrations::ParseXmlResponse::MalformedXmlError then 'INT-009'
      when Integrations::RenderTemplate::Error then 'INT-011'
      end
    end

    # Recorre los ancestros para que una subclase sin entrada propia herede el
    # código de su padre en vez de caer en el genérico.
    def code_by_class(error)
      error.class.ancestors.each do |ancestor|
        code = BY_CLASS[ancestor.name]
        return code if code
      end
      nil
    end

    private_class_method :adapter_code, :status_code, :cause_code, :code_by_class
  end
end
