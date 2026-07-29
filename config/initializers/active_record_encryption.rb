# frozen_string_literal: true

Rails.application.configure do
  config.active_record.encryption.primary_key =
    ENV.fetch('ENCRYPTION_KEY') { Rails.application.secret_key_base }
  config.active_record.encryption.key_derivation_salt =
    ENV.fetch('ENCRYPTION_KEY_DERIVATION_SALT') { Rails.application.secret_key_base }
  config.active_record.encryption.support_unencrypted_data = true
end
