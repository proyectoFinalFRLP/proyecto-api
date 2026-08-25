# frozen_string_literal: true

module Webhooks
  # Procesa un único FailedEvent. El claim es atómico (pending -> processing) para
  # que dos workers que reciban el mismo evento no lo reintenten dos veces, y lleva
  # `claimed_at` para que un claim abandonado (worker muerto) se pueda rescatar.
  class RetryFailedEventJob < ApplicationJob
    queue_as :low

    def perform(failed_event_id, company_id)
      with_tenant(company_id) do
        next unless claimed?(failed_event_id)

        RetryFailedEvent.new(failed_event: FailedEvent.find(failed_event_id)).call
      end
    end

    private

    # update_all a propósito: el claim tiene que ser una sola sentencia atómica.
    # Si afecta 0 filas, otro worker vivo ya se quedó con el evento. El scope
    # `claimable` incluye los claims vencidos: si no, un worker que muere después
    # de reclamar dejaría el evento en processing para siempre.
    def claimed?(failed_event_id)
      # rubocop:disable Rails/SkipsModelValidations
      claimed = FailedEvent.claimable.where(id: failed_event_id)
                           .update_all(status: 'processing', claimed_at: Time.current,
                                       updated_at: Time.current)
      # rubocop:enable Rails/SkipsModelValidations
      claimed == 1
    end
  end
end
