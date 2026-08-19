# frozen_string_literal: true

# Dead Letter Queue: un evento de integración que falló y espera ser reintentado.
# El motor de reintentos (app/poros/webhooks, app/jobs/webhooks) opera sobre esta tabla.
class FailedEvent < ApplicationRecord
  include CompanyScoped

  DEFAULT_MAX_ATTEMPTS = 5
  BASE_RETRY_DELAY = 1.minute
  MAX_JITTER = 30.seconds
  ERROR_LIMIT = 2_000
  # Un intento no puede durar más de los timeouts del HttpAdapter (10s + 10s):
  # pasado este margen, un evento que sigue en processing es un claim perdido.
  CLAIM_TIMEOUT = 5.minutes

  STATUSES = { pending: 'pending', processing: 'processing', succeeded: 'succeeded',
               dead: 'dead', discarded: 'discarded' }.freeze
  DIRECTIONS = { inbound: 'inbound', outbound: 'outbound' }.freeze

  belongs_to :company
  belongs_to :company_integration, optional: true

  enum :status, STATUSES, validate: true
  enum :direction, DIRECTIONS, validate: true, prefix: true

  validates :event_type, presence: true
  validates :attempts, numericality: { greater_than_or_equal_to: 0 }
  validates :max_attempts, numericality: { greater_than: 0 }

  scope :due, -> { pending.where(next_retry_at: ..Time.current) }

  # Visibility timeout: si el worker muere entre el claim y la persistencia del
  # resultado, el evento queda en processing sin nadie que lo termine. Pasado el
  # CLAIM_TIMEOUT se lo considera abandonado y vuelve a estar disponible.
  scope :stalled, -> { processing.where(claimed_at: ..CLAIM_TIMEOUT.ago) }

  # Lo que el barrido tiene que encolar: vencidos y claims abandonados.
  scope :retryable, -> { due.or(stalled) }

  # Lo que un worker puede reclamar: un pendiente, o un claim ya abandonado.
  scope :claimable, -> { pending.or(stalled) }

  # Backoff exponencial con jitter: 1m, 2m, 4m, 8m, 16m (+ hasta 30s de dispersión
  # para que un lote de eventos que falló junto no reintente todo en el mismo tick).
  def self.next_retry_at(attempts)
    Time.current + (BASE_RETRY_DELAY * (2**attempts)) + rand(MAX_JITTER.to_i).seconds
  end

  def attempts_exhausted? = attempts >= max_attempts

  # Misma condición que el scope :stalled, resuelta en memoria.
  def stalled? = processing? && claimed_at.present? && claimed_at <= CLAIM_TIMEOUT.ago
end
