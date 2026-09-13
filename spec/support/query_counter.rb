# frozen_string_literal: true

# Cuenta las consultas que matchean un patrón mientras corre el bloque.
#
# Vive acá y no duplicado en cada spec: lo usan los listados de productos y de
# órdenes para fijar que una página no dispare una consulta por fila, y dos
# copias textuales se desincronizan en cuanto una se toca.
module QueryCounter
  def count_queries(matching:, &block)
    count = 0
    counter = lambda do |_name, _started, _finished, _id, payload|
      count += 1 if payload[:sql].to_s.match?(matching)
    end

    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &block)

    count
  end
end

RSpec.configure do |config|
  config.include QueryCounter, type: :request
end
