# frozen_string_literal: true

require 'rails_helper'

# Hasta TESIS-130 la API respondía `Access-Control-Allow-Origin: *` a cualquier
# origen. Ahora sólo al front: en producción, la lista de CORS_ALLOWED_ORIGINS;
# en desarrollo y test, localhost en cualquier puerto (ADR-018).
RSpec.describe 'CORS', type: :request do
  def preflight(origin)
    options '/api/v1/auth/login', headers: {
      'Origin' => origin,
      'Access-Control-Request-Method' => 'POST',
      'Access-Control-Request-Headers' => 'content-type'
    }
  end

  def allowed_origin
    response.headers['Access-Control-Allow-Origin']
  end

  it 'lets the front dev server call the API' do
    preflight('http://localhost:5173')

    expect(allowed_origin).to eq('http://localhost:5173')
  end

  it 'answers other origins without the CORS headers' do
    preflight('https://evil.example')

    expect(allowed_origin).to be_nil
  end

  it 'does not take a host that only starts like localhost' do
    preflight('http://localhost.evil.example')

    expect(allowed_origin).to be_nil
  end

  # El ETag tiene que seguir expuesto: sin él, el front no manda If-Match y el
  # locking optimista de TESIS-101 se apaga sin que nada falle a la vista.
  it 'still exposes the ETag to the allowed origin', :aggregate_failures do
    get '/api/v1/tenant-config', params: { slug: 'norte' },
                                 headers: { 'Origin' => 'http://localhost:5173' }

    expect(allowed_origin).to eq('http://localhost:5173')
    expect(response.headers['Access-Control-Expose-Headers']).to include('ETag')
  end
end
