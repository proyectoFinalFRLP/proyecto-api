# frozen_string_literal: true

module Shipments
  # Confirma el despacho de un envío contra el operador logístico que el usuario
  # eligió después de cotizar (TESIS-47): le pide la etiqueta, se queda con el
  # número de seguimiento y la URL del PDF, y deja el envío listo para salir.
  #
  # Es el eslabón que faltaba entre la cotización (TESIS-46) y el seguimiento por
  # webhook (TESIS-48): sin `tracking_number` el push del courier no encuentra a
  # qué envío pertenece cada evento (ver ProcessTrackingUpdate#find_shipment).
  #
  # La llamada al courier corre FUERA de la transacción, y a propósito: una
  # transacción abierta mientras espera una API externa mantendría tomado el lock
  # de la fila todo lo que tarde la red. Lo que se escribe después es sólo lo que
  # el courier ya confirmó.
  class ConfirmDispatch < ApplicationPoro
    # Claves internas del contrato de despacho. Las plantillas mapean SUS nombres
    # externos a éstas, igual que en la cotización: el caso de uso no sabe cómo
    # las llama cada courier.
    TRACKING_KEY = 'tracking_number'
    LABEL_KEY = 'shipping_label_url'

    # Único estado que admite despacho: el envío recién creado (TESIS-105).
    DISPATCHABLE_STATUS = 'pending'

    # Estado al que pasa el envío una vez generada la etiqueta.
    DISPATCHED_STATUS = 'ready_to_ship'

    # El primer movimiento de la bitácora no viene del courier —todavía no
    # reportó nada—, así que el texto "crudo" lo pone el sistema. `external_status`
    # es NOT NULL y es lo que la pantalla muestra como lo que pasó (TESIS-60).
    INITIAL_EXTERNAL_STATUS = 'Etiqueta generada'

    # `shipping_cost` es el de la opción que el operador confirmó al cotizar
    # (TESIS-131). Es opcional: un despacho que no lo trae deja el costo como
    # estaba.
    def initialize(shipment:, company_integration:, origin_warehouse:, shipping_cost: nil)
      super()
      @shipment = shipment
      @integration = company_integration
      @origin = origin_warehouse
      @shipping_cost = shipping_cost
    end

    def call
      validate_integration!
      validate_status!(@shipment)

      parsed = request_label
      persist(parsed)
      @shipment
    end

    private

    # Se valida antes de llamar al courier para no gastar una etiqueta —que el
    # proveedor cobra— en un envío que después no vamos a poder guardar.
    #
    # El tracking se mira además del estado porque la card pide 409 "si ya tiene
    # un tracking asignado", y desde Avo se pueden editar los dos por separado:
    # un envío devuelto a `pending` a mano conserva su número, y despacharlo de
    # nuevo pisaría el tracking con el que el courier ya empuja eventos.
    def validate_status!(shipment)
      return if shipment.status == DISPATCHABLE_STATUS && shipment.tracking_number.blank?

      raise AlreadyDispatchedError.new(shipment: shipment)
    end

    def validate_integration!
      reason = integration_problem
      return if reason.nil?

      raise InvalidCourierIntegrationError.new(company_integration: @integration, reason: reason)
    end

    # Qué descalifica a la integración elegida. El orden va de lo más obvio a lo
    # más específico para que el mensaje sea el útil: una integración de
    # Tiendanube no es "una plantilla sin tracking", es un canal de venta.
    def integration_problem
      return 'it is not a courier integration' unless @integration.service.courier?
      return 'the integration is not active' unless @integration.is_active?
      # Antes que el mapeo: una plantilla de seguimiento sí mapea el número, y
      # decirle «no lo mapea» sería afirmar lo contrario de lo que pasa.
      return 'its template answers tracking queries, it does not dispatch' if tracking_template?
      return 'its template does not map a tracking number' unless dispatch_template?

      nil
    end

    # Mismo principio data-driven que `Service#quotes_shipping?`: la plantilla que
    # sabe despachar es la que declara dónde viene el número de seguimiento.
    def dispatch_template?
      @integration.service.dispatches_shipment?
    end

    def tracking_template?
      @integration.service.tracking_template?
    end

    def request_label
      Integrations::HttpAdapter.new(company_integration: @integration, payload: payload).call
    end

    # Contexto del despacho, en las claves internas que las plantillas mapean.
    # Mismo vocabulario que la cotización (QuoteShipment#payload) más los datos
    # del destinatario, que la etiqueta necesita imprimir.
    def payload
      {
        'origin_zip_code' => @origin.zip_code,
        'origin_address' => @origin.address,
        'destination_zip_code' => order.customer_zip_code,
        'destination_address' => order.customer_address,
        'customer_name' => order.customer_name,
        'customer_document' => order.customer_document,
        'total_weight' => total_weight,
        'total_items' => order.order_items.sum(:quantity)
      }
    end

    # Peso del paquete: peso × cantidad de cada ítem. `products.weight` arranca en
    # 0, así que un producto sin peso cargado suma cero en vez de romper.
    def total_weight
      order.order_items.includes(:product).sum { |item| item.product.weight * item.quantity }
    end

    def order
      @order ||= @shipment.order
    end

    # La transacción que pide la card: o queda el envío despachado con su primer
    # evento, o no queda nada.
    #
    # El `lock!` vuelve a leer la fila y se revalida el estado adentro: entre la
    # validación de arriba y esta escritura hubo una llamada de red, y en ese rato
    # otro request pudo despachar el mismo envío. El que pierde la carrera no pisa
    # el tracking del otro —hace rollback y sale por 409—, aunque haya gastado una
    # etiqueta. Evitarlo del todo exigiría sostener el lock durante la llamada
    # externa, que es justo lo que no se quiere.
    def persist(parsed)
      ActiveRecord::Base.transaction do
        @shipment.lock!
        validate_status!(@shipment)

        @shipment.update!(company_integration: @integration,
                          tracking_number: tracking_number!(parsed),
                          shipping_label_url: parsed[LABEL_KEY],
                          status: DISPATCHED_STATUS,
                          **confirmed_cost)
        register_event
      end
    end

    # El costo se escribe sólo si vino: sin él, el despacho no tiene por qué
    # borrar uno que ya estuviera cargado.
    def confirmed_cost
      @shipping_cost.nil? ? {} : { shipping_cost: @shipping_cost }
    end

    # Sin número de seguimiento el despacho no sirve para nada: no se puede
    # seguir el paquete ni emparejar los eventos que el courier empuje después.
    # La etiqueta, en cambio, puede faltar — no todos los proveedores devuelven
    # una URL, y el envío igual queda despachado.
    def tracking_number!(parsed)
      tracking = parsed[TRACKING_KEY]
      raise DispatchResponseError if tracking.blank?

      tracking
    end

    def register_event
      ShipmentEvent.create!(shipment: @shipment,
                            internal_status: DISPATCHED_STATUS,
                            external_status: INITIAL_EXTERNAL_STATUS,
                            description: event_description,
                            occurred_at: Time.current)
    end

    def event_description
      "#{@integration.service_name} · #{@shipment.tracking_number}"
    end
  end
end
