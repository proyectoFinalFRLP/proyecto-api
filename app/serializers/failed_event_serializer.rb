# frozen_string_literal: true

# El `payload` y el `last_response_body` no se exponen: pueden contener datos del
# cliente o de la respuesta del proveedor. Para diagnosticar alcanza con el
# mensaje de error y el status HTTP.
class FailedEventSerializer < ApplicationSerializer
  identifier :id

  fields :event_type, :direction, :status, :attempts, :max_attempts,
         :next_retry_at, :last_error, :last_response_status,
         :company_integration_id, :created_at, :updated_at
end
