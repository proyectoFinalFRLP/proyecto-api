# frozen_string_literal: true

module Api
  module V1
    class FailedEventsController < ApplicationController
      before_action :set_failed_event, only: %i[requeue discard]

      def index
        page = [params[:page].to_i, 1].max
        per_page = params.fetch(:per_page, 20).to_i.clamp(1, 100)

        events = filtered_events.order(created_at: :desc)
                                .offset((page - 1) * per_page)
                                .limit(per_page)

        render json: {
          data: FailedEventSerializer.render_as_hash(events),
          meta: { page: page, per_page: per_page, total: filtered_events.count }
        }
      end

      # POST /api/v1/failed-events/:id/retry (`retry` es palabra reservada en Ruby)
      def requeue
        event = ::Webhooks::RequeueFailedEvent.new(failed_event: @failed_event).call
        render json: FailedEventSerializer.render(event), status: :ok
      rescue ::Webhooks::RequeueFailedEvent::NotRequeueable => e
        render json: { error: e.message }, status: :unprocessable_content
      end

      def discard
        event = ::Webhooks::DiscardFailedEvent.new(failed_event: @failed_event).call
        render json: FailedEventSerializer.render(event), status: :ok
      end

      private

      # `scalar_param` y no `params[...]`: `?event_type[]=x` entrega un Array, y
      # `where` lo traduce a un `IN` —filtra por otra cosa que lo pedido, con un
      # 200 que no delata nada— mientras que `?event_type[foo]=x` levanta
      # TypeError y sale como 500. Mismo criterio que envíos y órdenes.
      def filtered_events
        events = policy_scope(FailedEvent)
        events = events.where(status: scalar_param(:status)) if valid_status?
        event_type = scalar_param(:event_type)
        events = events.where(event_type: event_type) if event_type.present?
        events
      end

      def valid_status?
        FailedEvent.statuses.key?(scalar_param(:status))
      end

      def set_failed_event
        @failed_event = FailedEvent.find(params.expect(:id))
        authorize @failed_event
      end
    end
  end
end
