# frozen_string_literal: true

module Admin
  class ServicesController < BaseController
    MAPPER_FIELDS = %w[request_mapper response_mapper request_value_mapper
                       response_value_mapper].freeze

    before_action :set_service, only: %i[show edit update]

    def index
      @services = Service.order(:id)
    end

    def show; end

    def new
      @service = Service.new
    end

    def edit; end

    def create
      @service = Service.new
      save_service(:new)
    end

    def update
      save_service(:edit)
    end

    private

    def set_service
      @service = Service.find(params.expect(:id))
    end

    def save_service(failure_view)
      @service.assign_attributes(scalar_params)
      assign_mappers
      if @service.errors.empty? && @service.save
        redirect_to admin_service_path(@service)
      else
        render failure_view, status: :unprocessable_content
      end
    end

    def scalar_params
      params.expect(service: %i[service_name type uri http_method])
    end

    def assign_mappers
      MAPPER_FIELDS.each do |field|
        raw = params[:service][field]
        next if raw.blank?

        assign_mapper(field, raw)
      end
    end

    def assign_mapper(field, raw)
      parsed = JSON.parse(raw)
      if parsed.is_a?(Hash)
        @service[field] = parsed
      else
        @service.errors.add(field, 'debe ser un objeto JSON (diccionario clave-valor)')
      end
    rescue JSON::ParserError
      @service.errors.add(field, 'no es un JSON válido')
    end
  end
end
