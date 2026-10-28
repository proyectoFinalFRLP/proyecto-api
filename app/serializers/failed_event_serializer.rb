# frozen_string_literal: true

# El `payload` y el `last_response_body` no se exponen: pueden contener datos del
# cliente o de la respuesta del proveedor. Para diagnosticar alcanza con el
# mensaje de error y el status HTTP.
#
# `error_code` y `error_message` son lo que lee el operador: el código de
# soporte y la causa en castellano (ADR-024). `last_error` sigue viajando para
# quien diagnostica: el front lo deja a mano en un tooltip, no en la celda.
class FailedEventSerializer < ApplicationSerializer
  identifier :id

  fields :event_type, :direction, :status, :attempts, :max_attempts,
         :next_retry_at, :error_code, :last_error, :last_response_status,
         :company_integration_id, :created_at, :updated_at

  field :error_message do |event|
    Webhooks::ErrorCatalog.message_for(event.error_code)
  end
end
