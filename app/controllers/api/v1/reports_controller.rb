# frozen_string_literal: true

module Api
  module V1
    class ReportsController < ApplicationController
      rescue_from Reports::Window::UnknownPeriodError, with: :render_bad_request

      # GET /api/v1/reports/overview?period=7d|30d|90d
      #
      # Un recurso y no una colección: viaja pelado, sin `data` (ADR-015).
      def overview
        authorize :report, :overview?

        window = Reports::Window.new(period: scalar_param(:period))
        render json: Reports::BuildOverview.new(window: window).call
      end
    end
  end
end
