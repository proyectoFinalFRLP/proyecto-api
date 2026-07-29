# frozen_string_literal: true

class WebhookLog < ApplicationRecord
  include CompanyScoped

  STATUSES = %w[pending processed failed].freeze

  belongs_to :company
  belongs_to :company_integration

  validates :status, presence: true, inclusion: { in: STATUSES }

  scope :pending, -> { where(status: 'pending') }
end
