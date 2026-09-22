# frozen_string_literal: true

module Shipments
  # Cronjob de la consulta periódica de tracking (config/recurring.yml,
  # TESIS-49). Igual que Webhooks::ScanDueFailedEventsJob, corre fuera de todo
  # tenant: barre las integraciones de todas las empresas con `unscoped` y
  # encola PollTrackingJob con el company_id de cada una.
  #
  # Sólo entran los couriers cuya plantilla tiene una de seguimiento
  # (Service#tracking_service) —los que empujan el tracking no la cargan— y, de
  # ellos, sólo los envíos en curso (Shipment.in_flight): un envío entregado no
  # se vuelve a consultar.
  #
  # Cómo se reparte el trabajo depende de la plantilla:
  # - consulta masiva: un job por lote de hasta BATCH_SIZE envíos;
  # - consulta individual: un job por envío.
  # En los dos casos los jobs de un mismo courier se escalonan para no llegarle
  # en ráfaga y quedar bloqueados por su límite de requests.
  class ScanPullTrackingJob < ApplicationJob
    queue_as :low

    # Números de seguimiento por request en una consulta masiva.
    BATCH_SIZE = 50

    # Separación entre dos requests al mismo courier...
    SPACING = 2.seconds

    # ...salvo que no entren en la ventana: con muchos envíos la separación se
    # achica para que la ronda se *encole* dentro de los 20 minutos y no se
    # encime con la siguiente del cron (cada 30).
    #
    # Lo que esto no garantiza es que la ronda *termine* ahí. PollTrackingJob
    # corre de a uno por integración (`limits_concurrency to: 1`), así que con
    # volumen la ronda dura lo que tarden sus requests uno atrás del otro, y
    # achicar la separación no lo acorta: pasado cierto punto, los jobs esperan
    # el semáforo y no el `wait`. Con el volumen de hoy (un lote de 50 envíos por
    # request en la consulta masiva) no se llega; si llega, dos rondas se
    # solapan y la segunda consulta envíos que la primera todavía no terminó.
    WINDOW = 20.minutes

    def perform
      pollable_integrations.each { |integration| enqueue_round(integration) }
    end

    private

    def pollable_integrations
      CompanyIntegration.unscoped.where(is_active: true)
                        .joins(:service).where.not(services: { tracking_service_id: nil })
                        .includes(service: :tracking_service)
    end

    def enqueue_round(integration)
      ids = Shipment.unscoped.in_flight.where(company_integration_id: integration.id)
                    .order(:id).pluck(:id)
      return if ids.empty?

      groups = ids.each_slice(group_size(integration)).to_a
      gap = [SPACING, WINDOW / groups.size].min
      groups.each_with_index do |group, index|
        PollTrackingJob.set(wait: gap * index)
                       .perform_later(integration.id, group, integration.company_id)
      end
    end

    def group_size(integration)
      integration.service.tracking_service.tracks_in_batch? ? BATCH_SIZE : 1
    end
  end
end
