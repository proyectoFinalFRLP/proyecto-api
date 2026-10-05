# frozen_string_literal: true

# Worker de Solid Queue para Windows.
#
# `bin/jobs` no arranca acá: el supervisor registra SIGQUIT, que no existe en la
# plataforma (architecture.md §8.3). Esto levanta un worker en el proceso
# actual, sin supervisor ni fork, que es todo lo que hace falta para ver correr
# la ingesta de webhooks y el sync de stock.
#
#   bundle exec rails runner bin/worker_windows.rb
#
# Corta con Ctrl-C.

COLAS = ENV.fetch('QUEUES', '*')

worker = SolidQueue::Worker.new(queues: COLAS, threads: 3, polling_interval: 0.5)
corriendo = true

# El handler no hace más que bajar la bandera. `worker.stop` puede terminar
# tomando un lock —al instrumentar con ActiveSupport::Notifications— y Ruby
# prohíbe tomar locks en contexto de trap: saldría un ThreadError en vez de un
# corte limpio. El worker se para abajo, en el hilo principal.
Signal.trap('INT') { corriendo = false }

puts "[worker] escuchando las colas: #{COLAS}"
puts '[worker] Ctrl-C para cortar'

# `start` levanta los hilos y vuelve enseguida: sin esta espera el proceso
# termina y el worker se muere sin tomar ningun job.
worker.start
sleep 0.5 while corriendo
worker.stop
puts '[worker] terminado'
