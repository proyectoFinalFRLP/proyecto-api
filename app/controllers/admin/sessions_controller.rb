# frozen_string_literal: true

module Admin
  class SessionsController < Devise::SessionsController
    layout 'admin_auth'

    private

    def after_sign_in_path_for(_resource)
      '/admin'
    end

    def after_sign_out_path_for(_scope)
      new_admin_user_session_path
    end
  end
end
