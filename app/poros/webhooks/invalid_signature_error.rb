# frozen_string_literal: true

module Webhooks
  # Un webhook que no prueba venir del proveedor (Webhooks::VerifySignature). El
  # mensaje dice qué falló, nunca el secreto ni la firma esperada: el gateway lo
  # loguea.
  class InvalidSignatureError < StandardError; end
end
