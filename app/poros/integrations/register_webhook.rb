# frozen_string_literal: true

module Integrations
  # Le pide al proveedor que avise a OneStock de cada evento de la cuenta (en
  # Shopify, cada venta: `orders/create`). Es lo que hace que las ventas entren
  # solas, sin que la empresa tenga que pegar una URL en ningún panel.
  #
  # Si la plantilla sabe suscribirse, se suscribe: la madre declara una hija
  # `webhook_subscription` y, opcional, una `webhook_lookup` que busca si ya
  # existe una suscripción a esta misma dirección. Con la búsqueda, registrar
  # dos veces no duplica nada; sin ella, el proveedor decide qué hacer con el
  # duplicado. Las dos contestan `webhook_subscription_id`.
  #
  # La dirección es la del gateway de esta integración sobre la URL pública de
  # la API (config.x.public_webhook_base_url). Si esa URL cambia (un túnel
  # nuevo en desarrollo), se vuelve a registrar y queda una suscripción más.
  #
  # Mismo contrato que TestConnection: nunca propaga el error del proveedor, lo
  # devuelve como mensaje para el backoffice.
  class RegisterWebhook < ApplicationPoro
    LOOKUP = :webhook_lookup
    SUBSCRIPTION = :webhook_subscription
    SUBSCRIPTION_KEY = 'webhook_subscription_id'
    URL_KEY = 'webhook_url'

    # Si la plantilla sabe suscribirse: el backoffice sólo ofrece registrar el
    # webhook donde tiene sentido.
    def self.declared_by?(service)
      service.present? && service.declares_operation?(SUBSCRIPTION)
    end

    def initialize(company_integration:, base_url: Rails.configuration.x.public_webhook_base_url)
      super()
      @integration = company_integration
      @base_url = base_url
    end

    def call
      template = service.template_for(SUBSCRIPTION)
      return failure("#{service.service_name} does not declare a subscription") unless template
      return failure('PUBLIC_WEBHOOK_BASE_URL is not set') if @base_url.blank?
      return success('already registered') if subscribed?

      subscribe(template)
    rescue AdapterExecutionError => e
      failure(e.message)
    end

    def webhook_url
      helpers = Rails.application.routes.url_helpers
      path = if service.courier?
               helpers.api_webhooks_courier_path(@integration.id)
             else
               helpers.api_webhooks_integration_path(@integration.id)
             end
      "#{@base_url}#{path}"
    end

    private

    def service = @integration.service

    def subscribed?
      lookup = service.template_for(LOOKUP)
      lookup.present? && run(lookup)[SUBSCRIPTION_KEY].present?
    end

    def subscribe(template)
      return success('registered') if run(template)[SUBSCRIPTION_KEY].present?

      failure("#{service.service_name} did not confirm the subscription")
    end

    def run(template)
      HttpAdapter.new(company_integration: @integration, service: template,
                      payload: { URL_KEY => webhook_url }).call
    end

    def success(what) = { ok: true, message: "Webhook #{what}: #{webhook_url}" }

    def failure(message) = { ok: false, message: message }
  end
end
