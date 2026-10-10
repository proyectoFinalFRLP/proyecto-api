# frozen_string_literal: true

class AddWebhookConfigToServices < ActiveRecord::Migration[8.1]
  # Cómo prueba el proveedor que un webhook es suyo. La plantilla lo declara
  # (algoritmo, header y de dónde sale el secreto) y el gateway lo verifica sobre
  # el body crudo antes de persistir. Vacío es «el proveedor no firma»: el
  # comportamiento de siempre para las plantillas que ya existían.
  def change
    add_column :services, :webhook_config, :jsonb, default: {}, null: false
  end
end
