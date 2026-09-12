# frozen_string_literal: true

module Api
  module V1
    # Sólo lectura. Nada en la API crea ni modifica envíos todavía: nacen al
    # confirmar el despacho (TESIS-105) y avanzan solos con el push de tracking
    # del courier (TESIS-48). Hasta que entre TESIS-105, los únicos envíos que
    # este endpoint devuelve son los sembrados por db/seeds.rb.
    class ShipmentsController < ApplicationController
      before_action :set_shipment, only: %i[show]

      def index
        page = [params[:page].to_i, 1].max
        per_page = params.fetch(:per_page, 20).to_i.clamp(1, 100)

        # La precarga es load-bearing: ShipmentListSerializer lee el nombre del
        # courier a través de la plantilla del Service, y sin ella son dos
        # queries por fila (company_integrations + services).
        shipments = filtered_shipments.preload(company_integration: :service)
                                      .order(created_at: :desc, id: :desc)
                                      .offset((page - 1) * per_page)
                                      .limit(per_page)

        render json: {
          data: ShipmentListSerializer.render_as_hash(shipments),
          # El total se cuenta sobre el scope filtrado, no sobre el total de la
          # empresa: de acá sale el KPI de envíos activos (TESIS-53).
          meta: { page: page, per_page: per_page, total: filtered_shipments.count }
        }
      end

      def show
        render json: ShipmentSerializer.render(@shipment)
      end

      private

      # Un status desconocido no se filtra ni se rechaza: `where` lo busca igual
      # y devuelve la lista vacía, que es la respuesta honesta para un filtro que
      # no matchea nada (status es un string plano, no un enum: no rompe).
      def filtered_shipments
        shipments = policy_scope(Shipment)
        shipments = shipments.where(status: params[:status]) if params[:status].present?
        shipments = shipments.where(order_id: params[:order_id]) if params[:order_id].present?
        shipments
      end

      # find y no find_by dentro del scope del tenant: el default_scope de
      # CompanyScoped ya acota, así que un id de otra empresa levanta
      # RecordNotFound -> 404, que es lo que corresponde (no revelar que existe).
      def set_shipment
        @shipment = Shipment.includes(:shipment_events, company_integration: :service)
                            .find(params.expect(:id))
        authorize @shipment
      end
    end
  end
end
