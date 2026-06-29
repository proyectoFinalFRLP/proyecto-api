# frozen_string_literal: true

class AddCompanyToUsers < ActiveRecord::Migration[8.1]
  def change
    add_reference :users, :company, null: false, foreign_key: { on_delete: :cascade }
  end
end
