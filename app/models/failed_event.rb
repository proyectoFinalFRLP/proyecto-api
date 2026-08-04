# frozen_string_literal: true

# Dead Letter Queue: un evento de integración que falló y espera ser reintentado.
# El motor de reintentos (app/poros/webhooks, app/jobs/webhooks) opera sobre esta tabla.
class FailedEvent < ApplicationRecord
  include CompanyScoped

  DEFAULT_MAX_ATTEMPTS = 5
  BASE_RETRY_DELAY = 1.minute
  MAX_JITTER = 30.seconds
  ERROR_LIMIT = 2_000

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

  # Backoff exponencial con jitter: 1m, 2m, 4m, 8m, 16m (+ hasta 30s de dispersión
  # para que un lote de eventos que falló junto no reintente todo en el mismo tick).
  def self.next_retry_at(attempts)
    Time.current + (BASE_RETRY_DELAY * (2**attempts)) + rand(MAX_JITTER.to_i).seconds
  end

  def attempts_exhausted? = attempts >= max_attempts
end
