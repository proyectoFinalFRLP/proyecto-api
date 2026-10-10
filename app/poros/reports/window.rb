# frozen_string_literal: true

module Reports
  # La ventana de tiempo de un reporte: los últimos N días calendario, en hora de
  # Argentina, desde el inicio del primer día hasta ahora.
  #
  # Hora de Argentina y no la del servidor (UTC): el MVP opera sólo en Argentina
  # (E4b, exclusión 9), y un corte de día en UTC partiría las ventas de las
  # 21 a las 24 en el día siguiente.
  #
  # El período anterior es la ventana del mismo largo inmediatamente antes, y es
  # contra lo que se calcula la tendencia.
  class Window
    class UnknownPeriodError < StandardError; end

    PERIODS = { '7d' => 7, '30d' => 30, '90d' => 90 }.freeze
    DEFAULT_PERIOD = '7d'
    # A partir de este largo la curva va por semana: 90 puntos diarios no se
    # leen en una tarjeta.
    WEEKLY_FROM = 90
    TIME_ZONE = 'America/Argentina/Buenos_Aires'

    attr_reader :period, :days, :from, :to

    def initialize(period:, now: Time.current)
      @period = period.presence || DEFAULT_PERIOD
      @days = PERIODS.fetch(@period) do
        raise UnknownPeriodError, "period must be one of #{PERIODS.keys.join(', ')}"
      end
      @to = now.in_time_zone(zone)
      @from = (@to.to_date - (@days - 1)).in_time_zone(zone).beginning_of_day
    end

    def range = from..to

    # Mismo largo, inmediatamente antes. Excluye el borde para no contar dos veces
    # lo que pasó justo en el inicio de la ventana actual.
    def previous_range = (from - days.days)...from

    def granularity = days >= WEEKLY_FROM ? 'week' : 'day'

    # El bucket al que pertenece un instante: su día, o el lunes de su semana.
    def bucket_for(time)
      date = time.in_time_zone(zone).to_date
      granularity == 'week' ? date.beginning_of_week : date
    end

    # Todos los buckets de la ventana, en orden, incluidos los que quedan vacíos:
    # una curva sin los días en cero dibujaría una línea entre dos ventas como si
    # hubiera habido ventas en el medio.
    def buckets
      (bucket_for(from)..to.to_date).select { |date| bucket_for(date) == date }
    end

    private

    def zone = ActiveSupport::TimeZone[TIME_ZONE]
  end
end
