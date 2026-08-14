# frozen_string_literal: true

class ShipmentEvent < ApplicationRecord
  # Sin company_id: el tenant se hereda del envío padre (lección TESIS-32).
  belongs_to :shipment

  validates :internal_status, presence: true
  validates :external_status, presence: true
  validates :occurred_at, presence: true
end
