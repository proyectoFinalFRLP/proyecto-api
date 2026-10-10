# frozen_string_literal: true

require 'rails_helper'

# En producción, CORS_ALLOWED_ORIGINS acepta un comodín para el subdominio de
# cada empresa (ADR-021). La suite corre sin la variable, así que estos ejemplos
# arman un Rack::Cors con el valor de producción: lo que se prueba es la regex
# que sale de CorsOrigins.parse, contra la forma en que rack-cors la aplica.
RSpec.describe CorsOrigins do
  def allowed?(origin, value: 'https://*.ejemplo.test')
    matchers = described_class.parse(value)
    cors = Rack::Cors.new(->(_env) { [200, {}, ['']] }) do
      allow do
        origins(*matchers)
        resource '*', headers: :any, methods: %i[get post]
      end
    end
    response = Rack::MockRequest.new(cors).request(
      'OPTIONS', '/api/v1/auth/login',
      'HTTP_ORIGIN' => origin, 'HTTP_ACCESS_CONTROL_REQUEST_METHOD' => 'POST'
    )

    response.headers['Access-Control-Allow-Origin'] == origin
  end

  %w[https://norte.ejemplo.test https://sur-2.ejemplo.test].each do |origin|
    it "lets in the company subdomain #{origin}" do
      expect(allowed?(origin)).to be(true)
    end
  end

  {
    'https://a.b.ejemplo.test' => 'two subdomain levels',
    'https://ejemplo.test' => 'no subdomain',
    'https://norte.ejemplo.test.evil.com' => 'the domain as a prefix of another',
    'https://evilejemplo.test' => 'the domain as a suffix of another',
    'http://norte.ejemplo.test' => 'plain HTTP',
    'https://norte.ejemplo.test:8443' => 'another port',
    'null' => 'an opaque origin',
    'http://localhost:5173' => 'the development fallback'
  }.each do |origin, reason|
    it "turns away #{origin} (#{reason})" do
      expect(allowed?(origin)).to be(false)
    end
  end

  it 'takes exact origins and wildcards in the same list', :aggregate_failures do
    value = 'https://app.otro.test, https://*.ejemplo.test'

    expect(allowed?('https://app.otro.test', value: value)).to be(true)
    expect(allowed?('https://norte.ejemplo.test', value: value)).to be(true)
    expect(allowed?('https://www.otro.test', value: value)).to be(false)
  end

  # En Ruby, ^ y $ anclan por línea: con ellos, un origen de dos líneas pasaría
  # por la segunda. Un header no puede traer un salto de línea, pero la regex
  # tiene que seguir anclada al string entero, con \A y \z.
  it 'anchors the whole origin, not one of its lines' do
    expect(allowed?("https://evil.example\nhttps://norte.ejemplo.test")).to be(false)
  end

  # Quien despliega podría escribir `*` esperando «todos»: el valor no puede
  # volver a abrir la API a cualquier origen.
  it 'does not read a bare asterisk as every origin' do
    expect(allowed?('https://evil.example', value: '*')).to be(false)
  end
end
