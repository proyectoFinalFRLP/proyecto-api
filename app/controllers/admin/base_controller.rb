# frozen_string_literal: true

module Admin
  class BaseController < ActionController::Base # rubocop:disable Rails/ApplicationController
    layout 'admin'

    before_action :authenticate_admin!

    private

    def authenticate_admin!
      authenticate_or_request_with_http_basic('Admin') do |username, password|
        valid_admin?(username, password)
      end
    end

    def valid_admin?(username, password)
      expected_username = admin_credential('ADMIN_USERNAME')
      expected_password = admin_credential('ADMIN_PASSWORD')
      return false if expected_username.blank? || expected_password.blank?

      ActiveSupport::SecurityUtils.secure_compare(username, expected_username) &
        ActiveSupport::SecurityUtils.secure_compare(password, expected_password)
    end

    def admin_credential(key)
      ENV.fetch(key) { 'admin' unless Rails.env.production? }
    end
  end
end
