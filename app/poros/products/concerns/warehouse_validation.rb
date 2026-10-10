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
        warehouse_ids = normalized_warehouse_ids!
        return if Warehouse.where(id: warehouse_ids).count == warehouse_ids.size

        # Mensaje genérico a propósito: no exponer IDs de depósitos de otro tenant.
        raise ActiveRecord::RecordNotSaved,
              'One or more warehouses do not belong to this company'
      end

      # Los ids del request como enteros únicos. Antes se comparaban crudos: una
      # fila sin `warehouse_id` hacía reventar el `sort` (nil contra Integer, un
      # 500), y ids que llegaban como texto ("5") no coincidían con los de la base
      # y daban un 422 falso de «no pertenece a esta empresa».
      def normalized_warehouse_ids!
        @stocks_params.map.with_index { |stock, index| warehouse_id_of!(stock, index) }.uniq
      end

      def warehouse_id_of!(stock, index)
        value = stock[:warehouse_id]
        id = value if value.is_a?(Integer)
        id ||= value.to_i if value.is_a?(String) && value.match?(/\A\d+\z/)
        return id if id&.positive?

        raise ActiveRecord::RecordNotSaved,
              "stocks[#{index}]: warehouse_id must be a positive integer"
      end
    end
  end
end
