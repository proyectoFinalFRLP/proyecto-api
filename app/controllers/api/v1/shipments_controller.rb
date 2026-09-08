# frozen_string_literal: true

module Api
  module V1
    # Lista, detalle y alta de envíos. El alta (TESIS-105) cuelga de la orden
    # —POST /api/v1/orders/:order_id/shipment— porque un envío nace siempre de
    # una: es el punto de entrada de la épica logística. Después de eso el envío
    # no se edita por esta API; avanza con el push de tracking del courier
    # (TESIS-48) y con la confirmación del despacho (TESIS-47).
    class ShipmentsController < ApplicationController
      before_action :set_shipment, only: %i[show]

      rescue_from Shipments::UnshippableOrderError, with: :render_unprocessable
      rescue_from Shipments::DuplicateShipmentError, with: :render_conflict

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

      def create
        # find y no find_by: Order es CompanyScoped, así que una orden de otra
        # empresa levanta RecordNotFound -> 404 y no confirma que exista.
        order = Order.find(params.expect(:order_id))
        # Se autoriza la orden y no el envío, igual que la cotización de
        # TESIS-46: el envío todavía no existe cuando corre el chequeo, y el
        # permiso es sobre la orden. ShipmentPolicy sigue siendo de sólo lectura.
        authorize order, :ship?

        shipment = Shipments::CreateShipment.new(order: order).call

        render json: ShipmentSerializer.render(shipment), status: :created
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

      # 409 y no 422: la orden ya tiene su envío, y no hay nada que el cliente
      # pueda corregir en el body para que el mismo request funcione.
      def render_conflict(exception)
        render json: { error: exception.message }, status: :conflict
      end
    end
  end
end
