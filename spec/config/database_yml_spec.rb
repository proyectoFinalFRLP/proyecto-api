# frozen_string_literal: true

require 'rails_helper'
require 'erb'
require 'yaml'

# ERB interpola el valor crudo en el YAML: sin comillas, el parser lo re-tipa.
# Estos ejemplos fijan que las credenciales que salen del entorno lleguen como
# el string exacto que se exportó, porque los tres casos de abajo son
# silenciosos y arruinan justo a la máquina que el valor por entorno existe
# para servir.
RSpec.describe 'config/database.yml' do # rubocop:disable RSpec/DescribeClass
  def resolve(*path)
    raw = Rails.root.join('config/database.yml').read
    YAML.safe_load(ERB.new(raw).result, aliases: true).dig(*path)
  end

  around do |example|
    previous = ENV.fetch('PROYECTO_API_DATABASE_PASSWORD', nil)
    example.run
    ENV['PROYECTO_API_DATABASE_PASSWORD'] = previous
  end

  # `on` es uno de los literales booleanos de YAML: sin comillas llega como
  # `true`, el driver manda "true" y la autenticación falla sin decir por qué.
  it 'keeps a password that YAML would read as a boolean' do
    ENV['PROYECTO_API_DATABASE_PASSWORD'] = 'on'

    expect(resolve('test', 'password')).to eq('on')
  end

  # Un `#` abre un comentario: sin comillas el valor entero desaparece.
  it 'keeps a password that starts with a comment marker' do
    ENV['PROYECTO_API_DATABASE_PASSWORD'] = '#secreta'

    expect(resolve('test', 'password')).to eq('#secreta')
  end

  # `: ` es el separador de clave y valor: sin comillas el archivo ni siquiera
  # parsea y la aplicación no arranca.
  it 'keeps a password containing a key separator' do
    ENV['PROYECTO_API_DATABASE_PASSWORD'] = 'ab: cd'

    expect(resolve('test', 'password')).to eq('ab: cd')
  end

  it 'falls back to the historical default when nothing is exported' do
    ENV.delete('PROYECTO_API_DATABASE_PASSWORD')

    expect(resolve('test', 'password')).to eq('admin')
  end

  # El bloque de producción pisaba el username del default con un literal, así
  # que la variable quedaba muerta ahí sin que nadie se enterara.
  it 'honours the user variable in production too' do
    ENV['PROYECTO_API_DATABASE_USER'] = 'otro_rol'

    expect(resolve('production', 'primary', 'username')).to eq('otro_rol')
  ensure
    ENV.delete('PROYECTO_API_DATABASE_USER')
  end
end
