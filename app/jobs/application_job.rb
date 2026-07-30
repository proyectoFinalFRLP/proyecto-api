# frozen_string_literal: true

class ApplicationJob < ActiveJob::Base
  # Colas declaradas en config/queue.yml; cada job elige la suya con queue_as.
  QUEUES = %i[realtime default low].freeze

  # Los fallos de APIs externas son transitorios: se reintentan con espera
  # creciente para no golpear un servicio caído. El resto de las excepciones
  # sube y el job queda marcado como fallido.
  retry_on Integrations::AdapterExecutionError, wait: :polynomially_longer, attempts: 5

  # Si el registro asociado ya no existe, el job perdió sentido.
  discard_on ActiveJob::DeserializationError

  # Los workers reutilizan sus threads entre jobs: sin limpiar el contexto, un
  # job podría heredar el tenant del anterior y leer datos de otra empresa.
  around_perform do |_job, block|
    block.call
  ensure
    Current.reset
  end

  private

  # Los jobs no tienen contexto HTTP: el tenant se pasa explícito y se activa
  # sólo durante el bloque.
  #
  # Falla si el company_id viene vacío en lugar de continuar: con Current.company_id
  # en nil el default_scope de CompanyScoped no se aplica y el job leería datos de
  # todas las empresas creyendo estar aislado.
  def with_tenant(company_id)
    raise ArgumentError, 'company_id is required to run inside a tenant' if company_id.blank?

    Current.company_id = company_id
    yield
  end
end
