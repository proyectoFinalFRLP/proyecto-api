# frozen_string_literal: true

module Catalog
  # El stock no se publicó porque al canal le falta configuración o al vínculo
  # le faltan referencias (Catalog::StockPublishRequirements). Nada salió hacia
  # el proveedor.
  #
  # No hereda de Integrations::AdapterExecutionError a propósito: ApplicationJob
  # reintenta ésa, y reintentar no completa un setting. El job falla en el acto
  # y queda en solid_queue_failed_executions con este mensaje, y el vínculo
  # guarda el motivo (`last_sync_error`) para que se vea en la pantalla.
  class ChannelNotReadyError < StandardError; end
end
