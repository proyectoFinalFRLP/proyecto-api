# El código de soporte de cada evento fallido (ADR-024). Los eventos nuevos lo
# reciben de Webhooks::ErrorCatalog al registrarse; los que ya estaban en la
# cola se completan acá, leyendo el `last_error` y el status que guardaron.
#
# SQL directo y no un recorrido de modelos: es una corrección de datos de una
# sola vez, no tiene que pasar por validaciones ni callbacks.
class AddErrorCodeToFailedEvents < ActiveRecord::Migration[8.1]
  ADAPTER = 'Integrations::AdapterExecutionError'

  # Copia congelada de Webhooks::ErrorCatalog::BY_CLASS al momento de esta
  # migración, y no la constante viva: si el catálogo suma o retira una clase
  # después, correr la migración en otra base tiene que dar lo mismo que dio acá.
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

  # Lo que el catálogo resuelve con la `cause` del AdapterExecutionError ya no
  # está guardado: sólo queda en el texto que armó el HttpAdapter. Por eso se
  # reconoce por esos textos, y sólo en filas de esa clase. El timeout va antes
  # que la red: `request failed: Net::ReadTimeout` también es un fallo de red.
  ADAPTER_PATTERNS = [
    ['INT-006', ['%request failed: Net::OpenTimeout%', '%request failed: Net::ReadTimeout%']],
    ['INT-007', ['%request failed: %']],
    ['INT-009', ['%returned a non-JSON response%', '%returned a non-XML response%',
                 '%returned an unreadable token response%']],
    ['INT-011', ['%has a broken template: %']],
    ['INT-008', ['% returned errors: %']]
  ].freeze

  # El mensaje de Orders::ProcessWebhookOrder::MISSING_ITEMS, guardado sin la
  # clase delante: así lo cargaban los datos de demostración.
  MISSING_ITEMS = 'the payload does not carry any order item'

  def up
    add_column :failed_events, :error_code, :string
    execute <<~SQL.squish
      UPDATE failed_events SET error_code = CASE #{branches.join(' ')} ELSE 'GEN-000' END
      WHERE last_error IS NOT NULL
    SQL
  end

  def down
    remove_column :failed_events, :error_code
  end

  private

  # El orden es el mismo que el de Webhooks::ErrorCatalog: primero el status
  # con el que contestó el proveedor, después la causa, después la clase.
  def branches
    status_branches + adapter_branches +
      ["WHEN last_error = #{quote(MISSING_ITEMS)} THEN 'ORD-001'"] + class_branches
  end

  def status_branches
    [
      "WHEN last_response_status IN (401, 403) THEN 'INT-002'",
      "WHEN last_response_status = 404 THEN 'INT-003'",
      "WHEN last_response_status = 429 THEN 'INT-004'",
      "WHEN last_response_status BETWEEN 500 AND 599 THEN 'INT-005'",
      "WHEN last_response_status BETWEEN 400 AND 499 THEN 'INT-008'"
    ]
  end

  def adapter_branches
    ADAPTER_PATTERNS.map do |code, patterns|
      matches = patterns.map { |pattern| "last_error LIKE #{quote(pattern)}" }.join(' OR ')
      "WHEN #{error_class} = #{quote(ADAPTER)} AND (#{matches}) THEN #{quote(code)}"
    end
  end

  def class_branches
    BY_CLASS.map { |name, code| "WHEN #{error_class} = #{quote(name)} THEN #{quote(code)}" }
  end

  # `last_error` se guarda como `Clase: mensaje` (Webhooks::FailureDetails).
  def error_class = "split_part(last_error, ': ', 1)"

  def quote(value) = connection.quote(value)
end
