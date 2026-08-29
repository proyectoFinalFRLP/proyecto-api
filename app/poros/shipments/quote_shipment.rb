# frozen_string_literal: true

module Shipments
  # Cotiza un envío contra todos los operadores logísticos activos de la empresa,
  # en paralelo, y devuelve una lista normalizada para que el usuario elija.
  #
  # El fallo de un courier no voltea la cotización: cada llamada se aísla y el
  # operador que no contesta simplemente no aparece entre las opciones. Es la
  # diferencia entre "no pudimos cotizar" y "no pudimos cotizar con Andreani".
  class QuoteShipment < ApplicationPoro
    # Claves internas del contrato de cotización. Las plantillas mapean SUS
    # nombres externos a estas: el motor no sabe cómo las llama cada courier.
    COST_KEY = 'shipping_cost'
    DAYS_KEY = 'estimated_days'

    # Más corto que el del adaptador (10s) a propósito: esto corre dentro de un
    # request y el usuario está esperando. La card pide 3-5s.
    OPEN_TIMEOUT = 4
    READ_TIMEOUT = 4

    def initialize(order:, origin_warehouse:)
      super()
      @order = order
      @origin = origin_warehouse
    end

    def call
      return [] if integrations.empty?

      # `payload` e `integrations` se resuelven ANTES de abrir los hilos: es
      # deliberado y load-bearing. Los hilos no pueden tocar ActiveRecord —
      # tomarían una conexión distinta del pool, que en test no ve la
      # transacción del ejemplo, y `Current.company_id` no cruza el límite del
      # hilo, así que el default_scope de CompanyScoped quedaría sin tenant.
      # Acá adentro sólo pasa HTTP.
      body = payload
      quotes = integrations.map { |integration| spawn_quote(integration, body) }.map(&:value)

      quotes.compact.sort_by { |quote| quote[:shipping_cost] }
    end

    private

    # Sólo las integraciones activas cuyo template sabe cotizar. Un courier puede
    # tener también una plantilla de despacho: ésa no contesta tarifas y pedírsela
    # sería llamar al endpoint equivocado (ver Service#quotes_shipping?).
    def integrations
      @integrations ||= CompanyIntegration.where(is_active: true)
                                          .joins(:service)
                                          .where(services: { type: Service::COURIER })
                                          .includes(:service)
                                          .select { |ci| ci.service.quotes_shipping? }
    end

    # El rescate va DENTRO del hilo: `Thread#value` re-levanta la excepción del
    # hilo en quien la espera, así que rescatar afuera cortaría la cotización
    # entera — justo lo que la card pide evitar.
    def spawn_quote(integration, body)
      Thread.new do
        # Un hilo que corre código de la aplicación tiene que declararlo con
        # `executor.wrap`: es lo que deja que Rails cargue constantes todavía no
        # autocargadas desde fuera del hilo principal, y lo que devuelve al pool
        # cualquier conexión que se hubiera tomado. Sin esto el comportamiento
        # queda indefinido — el caso feo es el autoload de Zeitwerk trabándose
        # contra el load interlock.
        Rails.application.executor.wrap { quote_with(integration, body) }
      rescue StandardError => e
        Rails.logger.warn(
          "[TESIS-46] #{integration.service.service_name} quote failed: #{e.class}: #{e.message}"
        )
        nil
      end
    end

    def quote_with(integration, body)
      parsed = Integrations::HttpAdapter.new(
        company_integration: integration, payload: body,
        open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT
      ).call

      normalize(integration, parsed)
    end

    # Una respuesta sin costo no es una opción que el usuario pueda elegir: se
    # descarta como si el operador no hubiera contestado, en vez de ofrecer una
    # tarifa vacía. `estimated_days` sí puede faltar — es informativo.
    def normalize(integration, parsed)
      cost = parsed[COST_KEY]
      return nil if cost.blank?

      { company_integration_id: integration.id,
        provider_name: integration.service.service_name,
        shipping_cost: BigDecimal(cost.to_s),
        estimated_days: parsed[DAYS_KEY]&.to_i }
    rescue ArgumentError
      # El courier contestó algo que no es un número en el campo del costo.
      nil
    end

    # Contexto del envío, en las claves internas que las plantillas mapean.
    def payload
      {
        'origin_zip_code' => @origin.zip_code,
        'origin_address' => @origin.address,
        'destination_zip_code' => @order.customer_zip_code,
        'destination_address' => @order.customer_address,
        'total_weight' => total_weight,
        'total_items' => @order.order_items.sum(:quantity)
      }
    end

    # Peso del paquete: la suma de peso × cantidad de cada ítem. `products.weight`
    # es decimal y arranca en 0, así que un producto sin peso cargado no rompe la
    # cotización — suma cero.
    def total_weight
      @order.order_items.includes(:product).sum { |item| item.product.weight * item.quantity }
    end
  end
end
