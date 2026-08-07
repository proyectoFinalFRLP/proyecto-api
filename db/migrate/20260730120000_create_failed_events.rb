# frozen_string_literal: true

class CreateFailedEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :failed_events do |t|
      t.references :company, null: false, foreign_key: { on_delete: :cascade }
      t.references :company_integration, foreign_key: { on_delete: :nullify }
      t.string :event_type, null: false
      t.string :direction, null: false, default: 'outbound'
      t.string :status, null: false, default: 'pending'
      t.jsonb :payload, null: false, default: {}
      t.integer :attempts, null: false, default: 0
      t.integer :max_attempts, null: false, default: 5
      t.datetime :next_retry_at
      t.text :last_error
      t.integer :last_response_status
      t.text :last_response_body

      t.timestamps
    end

    # Índice del barrido del cronjob: pendientes con el reintento ya vencido.
    add_index :failed_events, %i[status next_retry_at]
    add_index :failed_events, %i[company_id status]

    add_check_constraint :failed_events,
                         "status IN ('pending', 'processing', 'succeeded', 'dead', 'discarded')",
                         name: 'failed_events_status_check'
    add_check_constraint :failed_events, "direction IN ('inbound', 'outbound')",
                         name: 'failed_events_direction_check'
  end
end
