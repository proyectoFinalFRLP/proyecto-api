# frozen_string_literal: true

class CreateWebhookLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :webhook_logs do |t|
      t.references :company, null: false, foreign_key: { on_delete: :cascade }
      t.references :company_integration, null: false, foreign_key: { on_delete: :cascade }
      t.jsonb :headers, null: false, default: {}
      t.jsonb :payload, null: false, default: {}
      t.string :status, null: false, default: 'pending'
      t.text :error_message

      t.timestamps
    end

    add_index :webhook_logs, %i[status created_at]
    add_check_constraint :webhook_logs,
                         "status IN ('pending', 'processed', 'failed')",
                         name: 'webhook_logs_status_check'
  end
end
