# frozen_string_literal: true

module Webhooks
  module Replayers
    # Reprocesa una llamada saliente que había fallado, reconstruyéndola desde el
    # payload persistido en el FailedEvent.
    class HttpRequest < ApplicationPoro
      class MissingIntegration < StandardError; end

      def initialize(failed_event:)
        super()
        @event = failed_event
      end

      def call
        integration = @event.company_integration
        unless replayable?(integration)
          raise MissingIntegration, 'the company integration is missing or inactive'
        end

        Integrations::HttpAdapter.new(
          company_integration: integration,
          payload: @event.payload['payload'] || {},
          uri_params: @event.payload['uri_params'] || {}
        ).call
      end

      private

      def replayable?(integration) = integration.present? && integration.is_active?
    end
  end
end
