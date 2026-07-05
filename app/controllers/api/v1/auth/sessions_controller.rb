# frozen_string_literal: true

module Api
  module V1
    module Auth
      class SessionsController < ApplicationController
        def create
          token = ::Auth::AuthenticateUser.new(
            email: params[:email],
            password: params[:password]
          ).call

          if token
            render json: { token: token }, status: :ok
          else
            render json: { error: 'Invalid email or password' }, status: :unauthorized
          end
        end
      end
    end
  end
end
