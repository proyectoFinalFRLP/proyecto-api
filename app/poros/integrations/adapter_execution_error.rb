# frozen_string_literal: true

module Integrations
  # `rejected`: el proveedor contestó y rechazó el pedido con un error de
  # negocio en el body, aunque el HTTP sea 200 (Integrations::DetectResponseErrors).
  class AdapterExecutionError < StandardError
    attr_reader :payload, :response_status, :response_body

    def initialize(message, payload: nil, response_status: nil, response_body: nil,
                   rejected: false)
      super(message)
      @payload = payload
      @response_status = response_status
      @response_body = response_body
      @rejected = rejected
    end

    def rejected? = @rejected
  end
end
