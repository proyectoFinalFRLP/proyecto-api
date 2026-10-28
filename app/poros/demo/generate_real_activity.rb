# frozen_string_literal: true

module Demo
  # Actividad REAL para la demo: ventas nuevas despachadas con OCA.
  #
  # Reemplaza a la historia inventada que sembraban los seeds (dos meses de
  # ventas con números `DEMO-`): Reportes, Envíos y la bitácora se llenan con
  # lo que de verdad pasa al vender y despachar, día a día hasta la demo.
  #
  # Cada venta recorre los mismos casos de uso que la API, en el orden en que
  # los recorre el operador desde el front:
  #
  #   alta (Orders::CreateOrder: valida, toma los locks y descuenta el stock)
  #   → envío (Shipments::CreateShipment)
  #   → cotización (Shipments::QuoteShipment, contra todos los couriers activos)
  #   → despacho con la opción de OCA (Shipments::ConfirmDispatch)
  #
  # El despacho va contra el entorno de PRUEBA de OCA (ADR-022): devuelve un
  # número de envío y una orden de retiro reales, y la etiqueta se le pide a OCA.
  # Nada de fechas inventadas: todo queda fechado cuando corre.
  #
  # Una parte de las ventas queda sin despachar (envío pendiente), como pasa
  # con las ventas del día que todavía no salieron.
  #
  # Una venta que falla no corta a las demás: OCA caído, sin tarifa o sin stock
  # quedan en el resultado con el motivo. Lo que ya se hizo queda hecho, igual
  # que si el operador hubiera hecho lo mismo en el front: una orden cuyo
  # despacho falló sigue creada, con su envío pendiente.
  class GenerateRealActivity < ApplicationPoro
    # La plantilla que despacha (db/seeds/oca.rb).
    COURIER = 'OCA'

    # Unidades que cada fila de stock se guarda: la demo corre todos los días
    # hasta la defensa y no puede dejar el catálogo en cero. Una fila que llega
    # a este piso deja de usarse y aparece en las advertencias.
    STOCK_FLOOR = 5
    # Por debajo de esto (sobre el piso) se avisa que quedan pocas.
    LOW_SURPLUS = 5
    PENDING_SHARE = 0.2
    MAX_LINES = 2
    # Para un producto que nunca se vendió: los productos no tienen precio, el
    # precio es el de cada venta.
    DEFAULT_PRICE = 25_000

    Outcome = Data.define(:order_id, :customer, :status, :tracking_number, :shipping_cost,
                          :quotes, :error)
    Result = Data.define(:skipped, :outcomes, :warnings)

    def initialize(company:, count:, random: Random.new, pending_share: PENDING_SHARE)
      super()
      @company = company
      @count = count.to_i
      @random = random
      @pending_share = pending_share
    end

    def call
      Current.set(company_id: @company.id) do
        integration = courier_integration
        next skipped("#{@company.name} no tiene una integración activa de #{COURIER}") unless
          integration

        outcomes = Array.new(@count) { generate(integration) }
        Result.new(skipped: nil, outcomes: outcomes, warnings: stock_warnings)
      end
    end

    private

    def courier_integration
      CompanyIntegration.where(is_active: true).joins(:service)
                        .find_by(services: { service_name: COURIER })
    end

    def skipped(reason) = Result.new(skipped: reason, outcomes: [], warnings: [])

    def generate(integration)
      order = create_order
      return outcome(nil, :skipped, error: 'no queda stock por encima del piso') if order.nil?

      shipment = Shipments::CreateShipment.new(order: order).call
      return outcome(order, :pending) if @random.rand < @pending_share

      dispatch(order, shipment, integration)
    rescue StandardError => e
      outcome(order, :failed, error: "#{e.class}: #{e.message}")
    end

    def create_order
      warehouse, lines = pick_lines
      return if lines.empty?

      items = lines.map do |stock, quantity|
        { product_id: stock.product_id, quantity: quantity, unit_price: price_of(stock.product_id),
          warehouse_id: warehouse.id }
      end
      Orders::CreateOrder.new(params: RandomCustomer.new(random: @random).call, items: items,
                              company: @company).call
    end

    # El operador elige la opción de OCA entre las que contestaron. Con un solo
    # courier activo es la única, pero las demás quedan en el resultado.
    def dispatch(order, shipment, integration)
      origin = order.order_items.first.warehouse
      quotes = Shipments::QuoteShipment.for_order(order: order, origin_warehouse: origin).call
      chosen = quotes.find { |quote| quote[:dispatch_integration_id] == integration.id }
      summary = quotes.map { |quote| [quote[:provider_name], quote[:shipping_cost].to_f] }
      return outcome(order, :failed, quotes: summary, error: "#{COURIER} no cotizó") if chosen.nil?

      dispatched = Shipments::ConfirmDispatch.new(
        shipment: shipment, company_integration: integration, origin_warehouse: origin,
        shipping_cost: chosen[:shipping_cost], estimated_days: chosen[:estimated_days]
      ).call
      outcome(order, :dispatched, shipment: dispatched, quotes: summary)
    end

    def outcome(order, status, shipment: nil, quotes: [], error: nil)
      Outcome.new(order_id: order&.id, customer: order&.customer_name, status: status,
                  tracking_number: shipment&.tracking_number,
                  shipping_cost: shipment&.shipping_cost&.to_f, quotes: quotes, error: error)
    end

    # Un depósito y de 1 a MAX_LINES productos de ese depósito, al azar pero
    # pesando por lo que sobra del piso: lo que más hay es lo que más se vende,
    # y nada baja del piso. Todas las líneas salen del mismo depósito porque el
    # despacho tiene un solo origen.
    def pick_lines
      by_warehouse = available_stocks.group_by(&:warehouse)
      return [nil, []] if by_warehouse.empty?

      warehouse = weighted(by_warehouse.keys) { |w| by_warehouse[w].sum { |s| surplus(s) } }
      stocks = by_warehouse[warehouse].dup
      lines = Array.new([@random.rand(1..MAX_LINES), stocks.size].min) do
        stocks.delete(weighted(stocks) { |s| surplus(s) })
      end
      [warehouse, lines.map { |stock| [stock, quantity_for(stock)] }]
    end

    # Casi siempre una unidad; dos si sobra mucho.
    def quantity_for(stock)
      surplus(stock) >= 20 && @random.rand < 0.3 ? 2 : 1
    end

    # Sólo los productos que OCA puede cotizar: con peso y medidas.
    def available_stocks
      stocks.select { |stock| surplus(stock).positive? }
    end

    # Se relee en cada venta: la anterior acaba de descontar.
    def stocks
      shippable = Product.where('weight > 0').where.not(length_cm: nil)
                         .where.not(width_cm: nil).where.not(height_cm: nil)
      Stock.includes(:warehouse, :product)
           .where(product: shippable, warehouse: Warehouse.where.not(zip_code: nil))
           .order(:id).to_a
    end

    def surplus(stock) = stock.quantity - STOCK_FLOOR

    def weighted(items, &)
      target = @random.rand * items.sum(&)
      items.find { |item| (target -= yield(item)).negative? } || items.last
    end

    # El precio de la última venta del producto.
    def price_of(product_id)
      OrderItem.joins(:order).merge(Order.all).where(product_id: product_id)
               .order(id: :desc).pick(:unit_price) || DEFAULT_PRICE
    end

    def stock_warnings
      stocks.select { |stock| surplus(stock) <= LOW_SURPLUS }.map do |stock|
        "#{stock.product.sku} en #{stock.warehouse.name}: quedan #{stock.quantity} " \
          "(la demo no baja de #{STOCK_FLOOR})"
      end
    end
  end
end
