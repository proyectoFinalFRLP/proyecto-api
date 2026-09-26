# frozen_string_literal: true

# Límite de intentos fallidos por IP, compartido por los dos logins: el de la
# API (TESIS-82) y el del backoffice (TESIS-129). Sin él se podían probar
# contraseñas sin freno: después de 30 incorrectas seguidas, la correcta
# entraba igual.
#
# Se limita por IP y no con el :lockable de Devise, que bloquea la cuenta: con
# él, cualquiera podría dejar afuera a otro usuario tipeando mal su password a
# propósito. Y cuentan sólo los fallidos: el que entra no está adivinando nada.
#
# Quien lo incluye pone `before_action :refuse_exhausted_attempts` en su login,
# llama a count_failed_attempt cuando el login falla y define
# respond_too_many_attempts con el formato de su respuesta (JSON en la API, el
# formulario en el backoffice). Cada controller lleva su propia cuenta: agotar
# los intentos de la API no bloquea el backoffice desde la misma IP, ni al
# revés.
#
# El contador vive en la cache de la app, que en producción es Solid Cache y la
# comparten todos los procesos. En test la cache es :null_store y el límite
# nunca se alcanza, así los specs que loguean muchas veces no chocan con él;
# los specs del límite le dan una cache de verdad a propósito.
module FailedAttemptLimit
  extend ActiveSupport::Concern

  MAX_ATTEMPTS = 10
  WINDOW = 3.minutes

  private

  # Una vez agotados se rechaza sin mirar la password, también la correcta: si
  # se la evaluara, el que prueba contraseñas seguiría probando y la correcta
  # le daría el acceso igual.
  def refuse_exhausted_attempts
    render_too_many_attempts if failed_attempts >= MAX_ATTEMPTS
  end

  def render_too_many_attempts
    response.set_header('Retry-After', WINDOW.to_i.to_s)
    respond_too_many_attempts
  end

  # La ventana es fija: el increment de la cache conserva el vencimiento que
  # tomó la entrada con el primer fallo.
  def count_failed_attempt
    attempt_store.increment(failed_attempts_key, 1, expires_in: WINDOW)
  end

  # `raw: true` porque el valor lo escribió increment, que en algunos stores
  # guarda el entero sin serializar.
  def failed_attempts
    attempt_store.read(failed_attempts_key, raw: true).to_i
  end

  def failed_attempts_key
    "failed-attempts:#{controller_path}:#{request.remote_ip}"
  end

  def attempt_store
    self.class.cache_store
  end
end
