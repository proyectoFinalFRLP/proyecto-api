# frozen_string_literal: true

class AddInternalStatusCheckToShipmentEvents < ActiveRecord::Migration[8.1]
  def up
    add_check_constraint :shipment_events,
                         "internal_status IN ('pending', 'ready_to_ship', 'in_transit', 'delivered')",
                         name: 'shipment_events_internal_status_check'
  end

  def down
    remove_check_constraint :shipment_events, name: 'shipment_events_internal_status_check'
  end
end
