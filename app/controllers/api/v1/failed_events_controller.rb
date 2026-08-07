# frozen_string_literal: true

module Api
  module V1
    class FailedEventsController < ApplicationController
      MAX_PAGE_SIZE = 100

      before_action :set_failed_event, only: %i[requeue discard]

      def index
        render json: FailedEventSerializer.render(scoped_events)
      end

      # POST /api/v1/failed-events/:id/retry (`retry` es palabra reservada en Ruby)
      def requeue
        event = ::Webhooks::RequeueFailedEvent.new(failed_event: @failed_event).call
        render json: FailedEventSerializer.render(event), status: :ok
      rescue ::Webhooks::RequeueFailedEvent::NotRequeueable => e
        render json: { error: e.message }, status: :unprocessable_content
      end

      def discard
        @failed_event.update!(status: :discarded, next_retry_at: nil)
        render json: FailedEventSerializer.render(@failed_event), status: :ok
      end

      private

      def scoped_events
        events = policy_scope(FailedEvent).order(created_at: :desc).limit(MAX_PAGE_SIZE)
        events = events.where(status: params[:status]) if valid_status?
        events = events.where(event_type: params[:event_type]) if params[:event_type].present?
        events
      end

      def valid_status?
        FailedEvent.statuses.key?(params[:status])
      end

      def set_failed_event
        @failed_event = FailedEvent.find(params.expect(:id))
        authorize @failed_event
      end
    end
  end
end
