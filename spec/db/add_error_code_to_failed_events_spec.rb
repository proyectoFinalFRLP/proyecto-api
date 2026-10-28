# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20261027000409_add_error_code_to_failed_events')

# El código de soporte de los eventos que ya estaban en la cola antes de
# ADR-024: se deduce del `last_error` y del status que guardaron.
RSpec.describe AddErrorCodeToFailedEvents do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }

  # La base de test ya tiene la columna: se la saca para correr la migración
  # como en una base que no la tenía. El DDL de PostgreSQL es transaccional, así
  # que el rollback del ejemplo la deja como estaba.
  before do
    company
    ActiveRecord::Migration.suppress_messages { described_class.new.down }
    FailedEvent.reset_column_information
  end

  after { FailedEvent.reset_column_information }

  # SQL directo: sin la columna, el modelo no puede escribir una fila como las
  # que quedaron guardadas antes de esta migración.
  def stored(last_error, status = nil)
    ActiveRecord::Base.connection.select_value(<<~SQL.squish)
      INSERT INTO failed_events (company_id, event_type, last_error, last_response_status,
                                 payload, created_at, updated_at)
      VALUES (#{company.id}, 'integrations.http_request',
              #{ActiveRecord::Base.connection.quote(last_error)}, #{status || 'NULL'},
              '{}', now(), now())
      RETURNING id
    SQL
  end

  def code_after_migrating(last_error, status = nil)
    id = stored(last_error, status)
    ActiveRecord::Migration.suppress_messages { described_class.new.up }
    ActiveRecord::Base.connection.select_value("SELECT error_code FROM failed_events WHERE id = #{id}")
  end

  adapter = 'Integrations::AdapterExecutionError'
  {
    ["#{adapter}: Andreani responded with HTTP 503", 503] => 'INT-005',
    ["#{adapter}: Andreani responded with HTTP 401", 401] => 'INT-002',
    ["#{adapter}: Andreani responded with HTTP 404", 404] => 'INT-003',
    ["#{adapter}: Andreani responded with HTTP 429", 429] => 'INT-004',
    ["#{adapter}: Andreani responded with HTTP 422", 422] => 'INT-008',
    ["#{adapter}: Andreani request failed: Net::ReadTimeout: Net::ReadTimeout", nil] => 'INT-006',
    ["#{adapter}: Andreani request failed: Errno::ECONNREFUSED: refused", nil] => 'INT-007',
    ["#{adapter}: Andreani returned a non-JSON response", nil] => 'INT-009',
    ["#{adapter}: Andreani has a broken template: unknown filter", nil] => 'INT-011',
    ["#{adapter}: Shopify returned errors: Invalid", nil] => 'INT-008',
    ["#{adapter}: Andreani has an unsupported http_method: GO", nil] => 'INT-001',
    ['Integrations::MissingValueError: OCA needs height', nil] => 'INT-010',
    ["Orders::ProcessWebhookOrder::UnmappedProductError: 'MLA-1' is not mapped", nil] => 'ORD-002',
    ['Webhooks::Replayers::HttpRequest::MissingIntegration: inactive', nil] => 'INT-013',
    ['Webhooks::ReplayRegistry::UnknownEventType: no replayer', nil] => 'GEN-001',
    ['Catalog::LockTimeoutError: busy', nil] => 'STK-002',
    # Sin la clase delante, como lo guardaban los datos de demostración.
    ['the payload does not carry any order item', nil] => 'ORD-001',
    ['Service Unavailable', 503] => 'INT-005',
    ['NoMethodError: undefined method', nil] => 'GEN-000'
  }.each do |(last_error, status), code|
    it "codes #{last_error.inspect} as #{code}" do
      expect(code_after_migrating(last_error, status)).to eq(code)
    end
  end

  # Un evento sin error actual (uno ya resuelto) no tiene qué codificar.
  it 'leaves an event without a current error uncoded' do
    expect(code_after_migrating(nil)).to be_nil
  end
end
