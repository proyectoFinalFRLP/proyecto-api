# frozen_string_literal: true

module Products
  module Concerns
    module WarehouseValidation
      extend ActiveSupport::Concern

      private

      # Stock ya valida a nivel de modelo que producto y depósito pertenezcan a
      # la misma empresa (Stock#product_and_warehouse_must_belong_to_same_company).
      # Esta validación duplicada en los POROs da un mensaje de error más claro y
      # evita trabajo parcial dentro de la transacción (no crea stocks y después
      # revierte todo). Warehouse.where(id:) ya filtra por empresa vía el
      # default_scope de CompanyScoped, así que no hace falta repetir company_id.
      def validate_warehouses_belong_to_company!
        # rubocop:disable Rails/Pluck
        warehouse_ids = @stocks_params.map { |s| s[:warehouse_id] }.uniq
        # rubocop:enable Rails/Pluck
        owned = Warehouse.where(id: warehouse_ids).pluck(:id)
        return if owned.sort == warehouse_ids.sort

        # Mensaje genérico a propósito: no exponer IDs de depósitos de otro tenant.
        raise ActiveRecord::RecordNotSaved,
              'One or more warehouses do not belong to this company'
      end
    end
  end
end
