# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/seeds/oca').to_s

# La actividad real de la demo (sin red: OCA responde con las respuestas
# reales de su entorno de prueba guardadas en spec/fixtures/oca/).
RSpec.describe Demo::GenerateRealActivity do
  let(:company) { Company.create!(name: 'Norte', tax_id: '30-11111111-1', slug: 'norte') }
  let(:warehouse) do
    Warehouse.create!(company: company, name: 'Depósito Central', zip_code: '1900',
                      address: 'Av. 7 N° 1234', city: 'La Plata', province: 'Buenos Aires')
  end
  let(:product) do
    Product.create!(company: company, sku: 'NOR-004', name: 'Switch', weight: 0.35,
                    length_cm: 15, width_cm: 10, height_cm: 3)
  end
  let(:dispatches) { [] }

  def endpoint(method) = "#{OcaSeeds.base_uri}/#{method}"

  def stock = Stock.find_by!(product: product, warehouse: warehouse).quantity

  def generate(count: 2, pending_share: 0)
    described_class.new(company: company, count: count, random: Random.new(7),
                        pending_share: pending_share).call
  end

  def in_company(&) = Current.set(company_id: company.id, &)

  def shipments = in_company { Shipment.includes(company_integration: :service).to_a }

  before do
    OcaSeeds.install!
    OcaSeeds.connect_demo!(company)
    Stock.create!(product: product, warehouse: warehouse, quantity: 40)
    stub_request(:post, endpoint('Tarifar_Envio_Corporativo')).to_return(oca_xml('quote'))
    stub_request(:post, endpoint('IngresoORMultiplesRetiros_v2')).to_return do |request|
      dispatches << URI.decode_www_form(request.body).to_h
      oca_xml('dispatch')
    end
  end

  after { Current.reset }

  it 'sells, quotes and dispatches every order with OCA', :aggregate_failures do
    result = generate

    expect(result.outcomes.map(&:status)).to eq(%i[dispatched dispatched])
    expect(result.outcomes.map(&:tracking_number)).to all(eq('1217400000000340668'))
    expect(result.outcomes.map(&:shipping_cost)).to all(eq(181.92))
    expect(dispatches.size).to eq(2)
  end

  it 'leaves the shipments ready to ship with OCA, dated now', :aggregate_failures do
    generate

    expect(shipments.map(&:status)).to all(eq('ready_to_ship'))
    expect(shipments.map { |s| s.company_integration.service.service_name }).to all(eq('OCA'))
    expect(shipments.map(&:promised_delivery_on)).to all(be_present)
    expect(shipments.map(&:created_at)).to all(be_within(1.minute).of(Time.current))
  end

  it 'takes the units from the stock, as the API does' do
    initial = stock
    generate

    expect(stock).to eq(initial - in_company { OrderItem.sum(:quantity) })
  end

  it 'invents customers with an address OCA covers', :aggregate_failures do
    generate
    orders = in_company { Order.all.to_a }

    expect(orders.map(&:customer_name)).to all(be_present)
    expect(orders.map(&:customer_zip_code))
      .to all(be_in(Demo::RandomCustomer::DESTINATIONS.map(&:first)))
  end

  it 'leaves some orders without dispatching', :aggregate_failures do
    result = generate(pending_share: 1)

    expect(result.outcomes.map(&:status)).to eq(%i[pending pending])
    expect(in_company { Shipment.pluck(:status) }).to eq(%w[pending pending])
    expect(dispatches).to be_empty
  end

  context 'when OCA fails one dispatch' do
    before do
      stub_request(:post, endpoint('IngresoORMultiplesRetiros_v2'))
        .to_return(status: 500, body: oca_fixture('missing_parameter.txt')).then
        .to_return(oca_xml('dispatch'))
    end

    it 'reports it and goes on with the next order', :aggregate_failures do
      result = generate

      expect(result.outcomes.map(&:status)).to eq(%i[failed dispatched])
      expect(result.outcomes.first.error).to be_present
    end
  end

  it 'reports the order OCA did not quote', :aggregate_failures do
    stub_request(:post, endpoint('Tarifar_Envio_Corporativo')).to_return(oca_xml('quote_error'))

    result = generate(count: 1)

    expect(result.outcomes.first).to have_attributes(status: :failed, error: 'OCA no cotizó')
    expect(in_company { Shipment.pluck(:status) }).to eq(%w[pending])
  end

  it 'never sells below the stock floor', :aggregate_failures do
    Stock.find_by!(product: product).update!(quantity: described_class::STOCK_FLOOR + 1)

    result = generate(count: 3)

    expect(stock).to eq(described_class::STOCK_FLOOR)
    expect(result.outcomes.map(&:status)).to eq(%i[dispatched skipped skipped])
    expect(result.warnings).to include(a_string_including('NOR-004 en Depósito Central'))
  end

  it 'does nothing without an active OCA integration', :aggregate_failures do
    CompanyIntegration.where(company: company).find_each { |ci| ci.update!(is_active: false) }

    result = generate

    expect(result.skipped).to include('no tiene una integración activa de OCA')
    expect(Order.unscoped.count).to eq(0)
  end
end
