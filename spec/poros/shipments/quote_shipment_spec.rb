# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Shipments::QuoteShipment, type: :poro do
  subject(:quotes) { described_class.new(order: order, origin_warehouse: origin).call }

  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:origin) do
    Warehouse.create!(company: company, name: 'Central', zip_code: '1900', address: 'Calle 1')
  end
  let(:order) do
    Order.create!(company: company, customer_name: 'Ana', customer_zip_code: '5000',
                  customer_address: 'Av. Siempreviva 742')
  end

  def quoting_service(name, uri)
    Service.create!(service_name: name, type: 'courier', http_method: 'POST', uri: uri,
                    request_mapper: { 'cp' => 'destination_zip_code' },
                    response_mapper: { 'precio' => 'shipping_cost', 'dias' => 'estimated_days' },
                    request_value_mapper: {}, response_value_mapper: {})
  end

  def integrate(service)
    CompanyIntegration.create!(company: company, service: service,
                               credentials: { 'access_token' => 'T' }, is_active: true)
  end

  before { Current.company_id = company.id }

  after { Current.company_id = nil }

  context 'with two couriers that answer' do
    before do
      integrate(quoting_service('Fast', 'https://fast.test/rates'))
      integrate(quoting_service('Cheap', 'https://cheap.test/rates'))
      stub_request(:post, 'https://fast.test/rates')
        .to_return(status: 200, body: { precio: 2500.0, dias: 1 }.to_json)
      stub_request(:post, 'https://cheap.test/rates')
        .to_return(status: 200, body: { precio: 1800.0, dias: 5 }.to_json)
    end

    it 'returns one option per courier' do
      expect(quotes.length).to eq(2)
    end

    it 'sorts them by price so the cheapest comes first' do
      expect(quotes.pluck(:provider_name)).to eq(%w[Cheap Fast])
    end

    it 'normalizes the answer into the agreed shape' do
      expect(quotes.first).to include(provider_name: 'Cheap', shipping_cost: 1800.0,
                                      estimated_days: 5)
    end

    it 'reports which integration produced each option' do
      expect(quotes.pluck(:company_integration_id)).to all(be_present)
    end
  end

  # El paralelismo NO se verifica acá, y no por olvido: WebMock no es
  # thread-safe, y tres respuestas concurrentes con retardo cuelgan el proceso
  # —comprobado— en vez de fallar. La verificación de ese criterio de la card
  # está hecha contra un servidor HTTP real y documentada en el PR.
  context 'when one courier is down' do
    before do
      integrate(quoting_service('Fast', 'https://fast.test/rates'))
      integrate(quoting_service('Broken', 'https://broken.test/rates'))
      stub_request(:post, 'https://fast.test/rates')
        .to_return(status: 200, body: { precio: 2500.0, dias: 1 }.to_json)
      stub_request(:post, 'https://broken.test/rates').to_return(status: 500)
    end

    it 'still returns the ones that answered' do
      expect(quotes.pluck(:provider_name)).to eq(['Fast'])
    end

    it 'does not raise' do
      expect { quotes }.not_to raise_error
    end
  end

  context 'when every courier fails' do
    before do
      integrate(quoting_service('Broken', 'https://broken.test/rates'))
      stub_request(:post, 'https://broken.test/rates').to_timeout
    end

    it 'returns an empty list instead of raising' do
      expect(quotes).to eq([])
    end
  end

  context 'when a courier answers without a price' do
    before do
      integrate(quoting_service('Empty', 'https://empty.test/rates'))
      stub_request(:post, 'https://empty.test/rates')
        .to_return(status: 200, body: { dias: 3 }.to_json)
    end

    # Una tarifa vacía no es una opción elegible: se descarta como si el
    # operador no hubiera contestado.
    it 'drops the option' do
      expect(quotes).to eq([])
    end
  end

  # Los días son opcionales: hay couriers que cotizan el precio y no prometen
  # plazo. La opción tiene que llegar igual, con el plazo vacío, en vez de
  # descartarse o de viajar con un cero que el front mostraría como "0 días"
  # (TESIS-93).
  context 'when a courier quotes a price but no delivery time' do
    before do
      integrate(quoting_service('Fast', 'https://fast.test/rates'))
      stub_request(:post, 'https://fast.test/rates')
        .to_return(status: 200, body: { precio: 2500.0 }.to_json)
    end

    it 'keeps the option' do
      expect(quotes.length).to eq(1)
    end

    it 'leaves the estimate empty instead of inventing a zero' do
      expect(quotes.first[:estimated_days]).to be_nil
    end

    it 'still carries the price' do
      expect(quotes.first[:shipping_cost]).to eq(BigDecimal('2500.0'))
    end
  end

  # Un costo que no es un número: el courier contestó 'gratis', o un texto de
  # error en el campo del precio. La opción se descarta en vez de tumbar la
  # cotización entera, que es lo mismo que se hace cuando no manda precio.
  context 'when a courier answers a price that is not a number' do
    before do
      integrate(quoting_service('Fast', 'https://fast.test/rates'))
      integrate(quoting_service('Cheap', 'https://cheap.test/rates'))
      stub_request(:post, 'https://fast.test/rates')
        .to_return(status: 200, body: { precio: 'gratis', dias: 1 }.to_json)
      stub_request(:post, 'https://cheap.test/rates')
        .to_return(status: 200, body: { precio: 1800.0, dias: 5 }.to_json)
    end

    it 'drops that option' do
      expect(quotes.pluck(:provider_name)).to eq(['Cheap'])
    end

    it 'still returns the courier that answered a number' do
      expect(quotes.length).to eq(1)
    end

    it 'does not raise' do
      expect { quotes }.not_to raise_error
    end
  end

  context 'with a courier template that only knows how to dispatch' do
    before do
      dispatch = Service.create!(service_name: 'Andreani', type: 'courier', http_method: 'POST',
                                 uri: 'https://andreani.test/ordenes',
                                 request_mapper: {}, response_mapper: { 'id' => 'tracking_number' },
                                 request_value_mapper: {}, response_value_mapper: {})
      integrate(dispatch)
    end

    # Pedirle una tarifa sería llamar al endpoint equivocado del proveedor.
    it 'is not asked for a quote' do
      expect(quotes).to eq([])
    end
  end

  context 'with an inactive courier' do
    before do
      integration = integrate(quoting_service('Fast', 'https://fast.test/rates'))
      integration.update!(is_active: false)
    end

    it 'is skipped' do
      expect(quotes).to eq([])
    end
  end
end
