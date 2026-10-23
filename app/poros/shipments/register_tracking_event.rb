# frozen_string_literal: true

module Shipments
  # Registra en la bitácora de un envío un movimiento ya traducido por
  # TranslateTrackingPayload y, si corresponde, avanza shipments.status.
  #
  # Es el núcleo que comparten las dos formas de enterarse de un movimiento: el
  # push del courier (ProcessTrackingUpdate, TESIS-48) y la consulta periódica a
  # los que no tienen webhooks (PollTrackingStatus, TESIS-49). Las reglas de
  # idempotencia y orden son las mismas venga de donde venga el dato; lo que
  # cambia es qué hace cada camino con el resultado.
  #
  # Devuelve el ShipmentEvent creado, o nil si el movimiento ya estaba
  # registrado o llegó desordenado.
  #
  # `current_state:` dice que lo que llega es el estado ACTUAL del envío, como
  # en la consulta periódica, y no un movimiento suelto como el push. Sólo
  # importa cuando el courier da el día sin la hora (ver #day_precision_time).
  class RegisterTrackingEvent < ApplicationPoro
    def initialize(shipment:, translated:, current_state: false)
      super()
      @shipment = shipment
      @translated = translated
      @current_state = current_state
    end

    def call
      ActiveRecord::Base.transaction do
        # FOR UPDATE: serializa los eventos del mismo envío. Los chequeos de
        # duplicado/desorden van adentro del lock a propósito: afuera, dos
        # entregas simultáneas del mismo evento pasarían las dos.
        @shipment.lock!
        next if duplicate? || stale?

        event = ShipmentEvent.create!(event_attributes)
        @shipment.update!(status: @translated[:internal_status]) if advances_status?
        event
      end
    rescue ActiveRecord::RecordNotUnique
      # Otro worker ya escribió este mismo evento (mismo shipment_id +
      # external_status + occurred_at, ver índice único de la migración): la
      # bitácora ya lo tiene, no es un fallo.
      nil
    end

    private

    def event_attributes
      {
        shipment: @shipment,
        internal_status: internal_status,
        external_status: @translated[:external_status],
        description: @translated[:description],
        occurred_at: occurred_at
      }
    end

    # occurred_at es NOT NULL en la tabla; si el courier no lo mandó, usamos el
    # momento del procesamiento en lugar de fallar.
    def occurred_at
      @occurred_at ||= @translated[:occurred_at] || day_precision_time || Time.current
    end

    # El courier dijo el día y no la hora (`occurred_on`, TESIS-186: OCA informa
    # el estado actual con `dd/MM/yyyy`). Se registra al final de ese día, o
    # ahora si el día es hoy. Como no hay hora, el duplicado se mira por el
    # último estado (ver #duplicate?).
    #
    # Si lo que llega es el estado actual (la consulta periódica), además nunca
    # queda antes del último evento: sin hora no hay cómo ordenar dos eventos
    # del mismo día, y lo que contesta la consulta es lo más nuevo. Sin esto el
    # primer estado del día quedaba antes de «Etiqueta generada» y se
    # descartaba como desordenado. Un push, en cambio, puede llegar tarde: un
    # día anterior al del último evento se descarta como desordenado.
    def day_precision_time
      day = @translated[:occurred_on]
      return nil if day.nil?

      time = [day.end_of_day, Time.current].min
      @current_state ? [time, last_occurred_at].compact.max : time
    end

    def last_occurred_at
      @shipment.shipment_events.maximum(:occurred_at)
    end

    # Si la plantilla no supo traducir el estado externo (no está en el
    # response_value_mapper, o el valor traducido no pertenece a
    # Shipment::STATUSES), el evento igual se registra, pero como puramente
    # informativo: conserva el último estado conocido del envío en vez de
    # perder el movimiento o inventar un estado. Lo mismo si el estado
    # traducido es anterior al del envío (ver #advances_status?).
    def internal_status
      advances_status? ? @translated[:internal_status] : @shipment.status
    end

    # El envío sólo avanza en el orden de Shipment::STATUSES. Un courier puede
    # informar un estado que traducido queda atrás —OCA dice «En proceso de
    # Admision» después de «Retirado»—, y con fechas sin hora el orden de los
    # eventos no alcanza para descartarlo: un envío en camino volvía a «listo
    # para despachar», o uno entregado a «en camino». Ese movimiento queda en la
    # bitácora como informativo.
    #
    # Un envío que ya terminó (Shipment::TERMINAL_STATUSES) no se mueve más,
    # ni a otro final: los finales son alternativos, no pasos sucesivos, y su
    # orden en STATUSES no dice que uno venga después del otro. Un «Entregado»
    # que llega después de un «Devuelto al Remitente» queda informativo, igual
    # que un «Anulado» después de la entrega (TESIS-188).
    def advances_status?
      return false if @shipment.terminal?

      status_rank(@translated[:internal_status]) > status_rank(@shipment.status)
    end

    def status_rank(status)
      Shipment::STATUSES.index(status) || -1
    end

    def duplicate?
      return duplicate_without_timestamp? if @translated[:occurred_at].nil?

      @shipment.shipment_events.exists?(external_status: @translated[:external_status],
                                        occurred_at: occurred_at)
    end

    # Sin fecha del courier, occurred_at se sintetiza con Time.current en cada
    # entrega (ver occurred_at) y nunca coincide entre reintentos: comparar por
    # timestamp exacto no sirve para distinguir un reintento de un movimiento
    # legítimo. Para una bitácora de auditoría el default seguro es no duplicar,
    # así que acá se compara contra el último evento del envío por external_status.
    def duplicate_without_timestamp?
      last_event = @shipment.shipment_events.order(occurred_at: :desc).first
      last_event&.external_status == @translated[:external_status]
    end

    # Llegó desordenado: ya hay registrado un evento con occurred_at más nuevo
    # para este envío. Se descarta en lugar de pisar un estado más reciente.
    def stale?
      last = last_occurred_at
      last.present? && occurred_at < last
    end
  end
end
