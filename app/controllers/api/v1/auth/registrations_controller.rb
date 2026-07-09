# frozen_string_literal: true

module Api
  module V1
    module Auth
      class RegistrationsController < ApplicationController
        skip_before_action :authenticate_user!

        def create
          user = ::Auth::RegisterUser.new(params: user_params).call
          render json: UserSerializer.render(user), status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_content
        end

        private

        def user_params
          params.permit(:email, :password, :company_id)
        end
      end
    end
  end
end
