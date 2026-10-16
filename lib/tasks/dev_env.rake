# frozen_string_literal: true

# Lectura de las variables de las tareas de desarrollo que conectan una empresa
# con un proveedor real (`integrations:shopify:*`, `integrations:oca:*`).
#
# Rails no carga `.env` (no hay dotenv): estas tareas son las únicas que lo
# leen, y siempre después del entorno, que tiene prioridad. Así un secreto no
# se pega en la consola ni en un request.
#
# Es un `.rake` y no un `.rb` para que Rake lo cargue con el resto de las
# tareas: los módulos de cada proveedor lo usan recién al ejecutarse.
module DevEnv
  module_function

  # `PREFIX_<SLUG>_NAME`, del entorno o de `.env`. Corta la tarea si falta.
  def fetch(prefix, slug, name)
    optional(prefix, slug, name) ||
      abort("Falta #{key(prefix, slug, name)} en el entorno o en .env")
  end

  # Lo mismo, pero nil si no está.
  def optional(prefix, slug, name)
    variable = key(prefix, slug, name)
    ENV.fetch(variable) { dotenv[variable] }.presence
  end

  def key(prefix, slug, name) = "#{prefix}_#{slug.upcase}_#{name}"

  def dotenv
    path = Rails.root.join('.env')
    return {} unless path.exist?

    path.each_line.with_object({}) do |line, values|
      key, value = line.strip.split('=', 2)
      values[key] = value if key.present? && value && !key.start_with?('#')
    end
  end
end
