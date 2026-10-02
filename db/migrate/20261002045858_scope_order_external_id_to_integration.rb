# frozen_string_literal: true

# La venta externa se identifica por el canal que la mandó, no por la empresa:
# dos canales de la misma empresa pueden usar el mismo id (Mercado Libre y
# Tiendanube numeran cada uno por su lado). Con el índice por empresa, la
# segunda venta se tomaba por duplicada y se perdía sin dejar error.
#
# `company_integration_id` ya implica la empresa: cada integración es de una
# sola. Las órdenes manuales no tienen id externo (el alta no lo permite), así
# que el NULL de la integración no deja nada sin cubrir.
class ScopeOrderExternalIdToIntegration < ActiveRecord::Migration[8.1]
  def change
    remove_index :orders, %i[company_id external_order_id], unique: true,
                                                            name: 'index_orders_on_company_id_and_external_order_id'
    add_index :orders, %i[company_integration_id external_order_id],
              unique: true, name: 'index_orders_on_integration_and_external_order_id'
  end
end
