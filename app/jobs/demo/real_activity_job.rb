# frozen_string_literal: true

module Demo
  # La actividad real de la demo, sola, en el entorno desplegado: unas pocas
  # ventas despachadas con OCA varias veces por día (config/recurring.yml), así
  # Reportes muestra una curva hecha de despachos de verdad hasta la defensa.
  # La lógica es la de Demo::GenerateRealActivity, la misma que corre
  # `bin/rails "demo:real_activity[norte]"`.
  #
  # No hace nada salvo que se lo pida el entorno, y nunca toca a otra empresa:
  #
  #   DEMO_ACTIVITY_COMPANY=norte        el slug de la única empresa que vende
  #   DEMO_ACTIVITY_UNTIL=2026-11-10     opcional: después de ese día, nada
  #
  # Así se apaga sin desplegar código: se borra la variable (o vence la fecha)
  # y el cron sigue corriendo sin efecto.
  #
  # No se reintenta: cada corrida crea órdenes y pide retiros a OCA, y un
  # reintento las duplicaría. Una venta que falla ya queda informada en el log;
  # la próxima corrida es la siguiente oportunidad.
  class RealActivityJob < ApplicationJob
    queue_as :low

    # Dos corridas a la vez venderían el mismo stock en paralelo.
    limits_concurrency to: 1, key: 'demo_real_activity', duration: 15.minutes

    COMPANY_VARIABLE = 'DEMO_ACTIVITY_COMPANY'
    UNTIL_VARIABLE = 'DEMO_ACTIVITY_UNTIL'
    # Las fechas de la demo son de Argentina, no del reloj del servidor (UTC).
    ZONE = 'America/Argentina/Buenos_Aires'
    DEFAULT_COUNTS = (2..4)
    LOG_TAG = '[Demo::RealActivityJob]'

    # `count` vacío: entre 2 y 4 ventas, para que la curva no sea una escalera.
    def perform(count = nil)
      company = enabled_company
      return if company.nil?

      with_tenant(company.id) do
        result = GenerateRealActivity.new(company: company, count: count || rand(DEFAULT_COUNTS))
                                     .call
        log(company, result)
      end
    end

    private

    def enabled_company
      slug = ENV.fetch(COMPANY_VARIABLE, '').strip
      return if slug.empty? || expired?

      Company.find_by(slug: slug).tap do |company|
        Rails.logger.warn("#{LOG_TAG} no company with slug #{slug}") if company.nil?
      end
    end

    def expired?
      last_day = ENV.fetch(UNTIL_VARIABLE, '').strip
      return false if last_day.empty?

      Time.find_zone!(ZONE).today > Date.iso8601(last_day)
    rescue Date::Error
      Rails.logger.warn("#{LOG_TAG} #{UNTIL_VARIABLE}=#{last_day} is not a YYYY-MM-DD date")
      true
    end

    def log(company, result)
      return Rails.logger.info("#{LOG_TAG} #{company.slug}: skipped, #{result.skipped}") if
        result.skipped

      result.outcomes.each do |outcome|
        Rails.logger.info("#{LOG_TAG} #{company.slug}: #{outcome.to_h.compact.except(:quotes)}")
      end
      result.warnings.each { |warning| Rails.logger.warn("#{LOG_TAG} #{warning}") }
    end
  end
end
