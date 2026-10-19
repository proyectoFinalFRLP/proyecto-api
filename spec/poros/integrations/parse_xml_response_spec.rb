# frozen_string_literal: true

require 'rails_helper'

# Las respuestas son reales: el entorno de prueba de OCA e-Pak (TESIS-186).
RSpec.describe Integrations::ParseXmlResponse, type: :poro do
  def parse(body) = described_class.new(body).call

  it 'opens a .NET DataSet: no schema, no diffgram, rows under the root', :aggregate_failures do
    result = parse(oca_fixture('quote.xml'))

    expect(result.keys).to eq(['Table'])
    expect(result['Table']).to include('Precio' => '181.9200', 'Total' => '181.9200',
                                       'PlazoEntrega' => '1', 'Ambito' => 'Principales')
  end

  it 'keeps the rows of a dataset with another name' do
    result = parse(oca_fixture('dispatch.xml'))

    expect(result['DetalleIngresos']).to include('OrdenRetiro' => '20914118',
                                                 'NumeroEnvio' => '1217400000000340668')
  end

  it 'turns repeated rows into a list' do
    expect(parse(oca_fixture('connection_test.xml'))['Table'].pluck('IdOperativa'))
      .to eq(%w[50007 50011])
  end

  it 'strips the padding of fixed-width fields and reads empty elements as nil' do
    result = parse(<<~XML)
      <DataSet><Table><codigopostal>1824    </codigopostal><PisoRetiro /></Table></DataSet>
    XML
    expect(result).to eq('Table' => { 'codigopostal' => '1824', 'PisoRetiro' => nil })
  end

  it 'answers an empty dataset with an empty Hash' do
    expect(parse(oca_fixture('connection_test_empty.xml'))).to eq({})
  end

  it 'keeps a bare text root under its name' do
    expect(parse(oca_fixture('label.xml'))['string']).to start_with('JVBERi0xLjQ')
  end

  it 'parses a text that is itself an XML document' do
    body = '<string xmlns="#x">&lt;Rows&gt;&lt;Row&gt;&lt;Id&gt;7&lt;/Id&gt;&lt;/Row&gt;&lt;/Rows&gt;</string>'
    expect(parse(body)).to eq('Row' => { 'Id' => '7' })
  end

  it 'raises on something that is not XML' do
    expect { parse('Missing parameter: Operativa.') }
      .to raise_error(described_class::MalformedXmlError)
  end
end
