# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Integrations::DetectResponseErrors, type: :poro do
  let(:service) do
    Service.new(service_name: 'OCA e-Pak', type: 'courier', uri: 'https://oca.test',
                http_method: 'POST', error_path: 'Error, DetalleRechazos.0.Motivo')
  end

  def detect(body) = described_class.new(service: service, body: body).call

  it 'lets a body without errors through' do
    expect { detect('DetalleIngresos' => { 'NumeroEnvio' => '1' }) }.not_to raise_error
  end

  it 'reads every path declared, separated by commas', :aggregate_failures do
    expect { detect('DetalleRechazos' => { 'Motivo' => 'CP inexistente' }) }
      .to raise_error(Integrations::AdapterExecutionError, /CP inexistente/)
    expect { detect('Error' => { 'Descripcion' => 'Usuario o contraseña incorrectos' }) }
      .to raise_error(Integrations::AdapterExecutionError,
                      'OCA e-Pak returned errors: Usuario o contraseña incorrectos')
  end

  it 'marks the error as a rejection by the provider', :aggregate_failures do
    expect { detect('Error' => { 'Descripcion' => 'x' }) }
      .to raise_error(Integrations::AdapterExecutionError) { |error| expect(error).to be_rejected }
  end

  it 'ignores an empty value at the error path' do
    expect { detect('Error' => nil, 'DetalleRechazos' => { 'Motivo' => '' }) }.not_to raise_error
  end

  it 'reads the real error of an OCA dispatch (HTTP 200)' do
    body = Integrations::ParseXmlResponse.new(oca_fixture('dispatch_error.xml')).call
    expect { detect(body) }.to raise_error(Integrations::AdapterExecutionError,
                                           /Usuario o contraseña incorrectos/)
  end
end
