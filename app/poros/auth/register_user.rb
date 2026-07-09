# frozen_string_literal: true

module Auth
  class RegisterUser < ApplicationPoro
    def initialize(params:)
      super()
      @params = params
    end

    def call
      User.create!(@params)
    end
  end
end
