# frozen_string_literal: true

class ShipmentEvent < ApplicationRecord
  # Sin company_id: el tenant se hereda del envío padre (lección TESIS-32).
  belongs_to :shipment

  # Reutiliza el vocabulario normalizado del envío: el sistema escribe estos
  # valores; el courier escribe el crudo en external_status.
  validates :internal_status, presence: true, inclusion: { in: Shipment::STATUSES }
  validates :external_status, presence: true
  validates :occurred_at, presence: true
end
