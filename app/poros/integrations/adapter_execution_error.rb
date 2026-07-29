# frozen_string_literal: true

module Integrations
  class AdapterExecutionError < StandardError
    attr_reader :payload, :response_status, :response_body

    def initialize(message, payload: nil, response_status: nil, response_body: nil)
      super(message)
      @payload = payload
      @response_status = response_status
      @response_body = response_body
    end
  end
end
