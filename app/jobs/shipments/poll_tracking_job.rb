# frozen_string_literal: true

module Shipments
  # Consulta al courier por el estado de un grupo de envíos de una misma
  # integración (TESIS-49). Lo encola el barrido periódico
  # (ScanPullTrackingJob): un job por envío si la plantilla sólo contesta de a
  # uno, o uno por lote si acepta consultas masivas.
  #
  # Cola low: es una sincronización de fondo. Nadie está esperando la respuesta,
  # y el vendedor ya asume la demora de un ciclo del cron.
  class PollTrackingJob < ApplicationJob
    queue_as :low

    # Un solo request a la vez por integración: los jobs de un mismo courier se
    # encolan escalonados, pero si una ronda se atrasa y se pisa con la
    # siguiente, esto evita que la cola termine ráfagas contra su API. El
    # `duration` libera el semáforo si un worker muere sosteniéndolo.
    limits_concurrency to: 1, key: ->(company_integration_id, *) { company_integration_id },
                       duration: 5.minutes

    def perform(company_integration_id, shipment_ids, company_id)
      with_tenant(company_id) do
        integration = CompanyIntegration.find_by(id: company_integration_id)
        # Borrada o desactivada entre el barrido y la ejecución: no se le pregunta.
        next unless integration&.is_active?

        Shipments::PollTrackingStatus.new(company_integration: integration,
                                          shipment_ids: shipment_ids).call
      end
    end
  end
end
