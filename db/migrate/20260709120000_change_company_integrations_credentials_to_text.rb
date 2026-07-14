# frozen_string_literal: true

class ChangeCompanyIntegrationsCredentialsToText < ActiveRecord::Migration[8.1]
  def up
    change_column_default :company_integrations, :credentials, nil
    change_column :company_integrations, :credentials, :text, using: 'credentials::text'
    change_column_default :company_integrations, :credentials, '{}'
  end

  def down
    change_column_default :company_integrations, :credentials, nil
    change_column :company_integrations, :credentials, :jsonb, using: 'credentials::jsonb'
    change_column_default :company_integrations, :credentials, {}
  end
end
