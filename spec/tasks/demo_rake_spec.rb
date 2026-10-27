# frozen_string_literal: true

require 'rails_helper'
require 'rake'
require Rails.root.join('db/seeds/oca').to_s

# Las tareas de la demo (lib/tasks/demo.rake), con OCA sin red: responde con
# las respuestas reales de su entorno de prueba (spec/fixtures/oca/).
RSpec.describe 'demo rake tasks' do # rubocop:disable RSpec/DescribeClass
  let(:company) { Company.create!(name: 'Norte', tax_id: '30-11111111-1', slug: 'norte') }
  let(:warehouse) do
    Warehouse.create!(company: company, name: 'Depósito Central', zip_code: '1900',
                      address: 'Av. 7 N° 1234', city: 'La Plata', province: 'Buenos Aires')
  end
  let(:product) do
    Product.create!(company: company, sku: 'NOR-004', name: 'Switch', weight: 0.35,
                    length_cm: 15, width_cm: 10, height_cm: 3)
  end

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?('demo:real_activity')
    OcaSeeds.install!
  end

  after { Current.reset }

  def run(task, *args)
    Rake::Task[task].reenable
    Rake::Task[task].invoke(*args)
  end

  def endpoint(method) = "#{OcaSeeds.base_uri}/#{method}"

  def in_company(&) = Current.set(company_id: company.id, &)

  describe 'demo:real_activity' do
    before do
      OcaSeeds.connect_demo!(company)
      Stock.create!(product: product, warehouse: warehouse, quantity: 40)
      stub_request(:post, endpoint('Tarifar_Envio_Corporativo')).to_return(oca_xml('quote'))
      stub_request(:post, endpoint('IngresoORMultiplesRetiros_v2')).to_return(oca_xml('dispatch'))
      allow(Demo::GenerateRealActivity).to receive(:new).and_wrap_original do |original, **args|
        original.call(**args, pending_share: 0)
      end
    end

    it 'prints each order with its OCA tracking number and a summary' do
      expect { run('demo:real_activity', 'norte', '2') }.to output(
        /OCA 1217400000000340668, \$181\.92.*Resumen: 2 pedidas, 2 despachadas, 0 pendientes, 0 con error\. Costo de envío total: \$363\.84/m
      ).to_stdout
    end

    it 'stops when the company is not connected to OCA' do
      CompanyIntegration.where(company: company).delete_all

      expect { run('demo:real_activity', 'norte', '2') }
        .to raise_error(SystemExit).and output(/no está conectada a OCA/).to_stderr
    end
  end

  describe 'demo:purge_seeded_history' do
    # Lo que sembraba db/seeds/demo_activity.rb, y lo que no hay que tocar.
    let!(:seeded) do
      in_company do
        [sale('Hotel Bristol', tracking: 'DEMO-000105'), sale('Kiosco El Sol'),
         FailedEvent.create!(company: company, company_integration: fake_channel,
                             direction: 'inbound', event_type: 'webhooks.order_ingestion',
                             status: 'dead', attempts: 5,
                             last_error: 'the payload does not carry any order item'),
         FailedEvent.create!(company: company, company_integration: fake_channel,
                             direction: 'outbound', event_type: 'integrations.http_request',
                             status: 'pending', attempts: 2, last_response_status: 503,
                             last_error: 'Service Unavailable', payload: {})]
      end
    end
    let!(:kept) do
      in_company do
        [sale('Hotel Bristol', tracking: '1217400000000340668'), sale('Lucía González'),
         FailedEvent.create!(company: company, direction: 'outbound', status: 'pending',
                             event_type: 'integrations.http_request', attempts: 1,
                             last_response_status: 503, last_error: 'Service Unavailable')]
      end
    end

    # La conexión de ejemplo de Mercado Libre: se la reconoce por el token.
    def fake_channel
      @fake_channel ||= CompanyIntegration.create!(
        company: company, service: Service.find_by!(service_name: 'OCA'),
        credentials: { 'access_token' => 'DEMO-TOKEN-ML' }, is_active: false
      )
    end

    def sale(customer, tracking: nil)
      order = Order.create!(company: company, customer_name: customer, status: 'paid',
                            order_items: [OrderItem.new(product: product, warehouse: warehouse,
                                                        quantity: 1, unit_price: 100)])
      return order if tracking.nil?

      shipment = Shipment.create!(company: company, order: order, status: 'delivered',
                                  tracking_number: tracking)
      ShipmentEvent.create!(shipment: shipment, internal_status: 'delivered',
                            external_status: 'Entregado', occurred_at: 1.day.ago)
      order
    end

    def exists?(record) = record.class.unscoped.exists?(record.id)

    it 'only lists what it would delete with dry_run', :aggregate_failures do
      expect { run('demo:purge_seeded_history', 'norte', 'dry_run') }
        .to output(/Borraría 2 órdenes, 1 envíos y 2 eventos fallidos:.*Hotel Bristol DEMO-000105/m)
        .to_stdout
      expect(seeded + kept).to all(satisfy { |record| exists?(record) })
    end

    context 'when it runs for real' do
      before do
        allow($stdout).to receive(:puts)
        run('demo:purge_seeded_history', 'norte')
      end

      it 'deletes the invented sales, their shipments and events', :aggregate_failures do
        expect(seeded.map { |record| exists?(record) }).to all(be(false))
        expect(ShipmentEvent.unscoped.count).to eq(1)
      end

      it 'keeps everything else' do
        expect(kept).to all(satisfy { |record| exists?(record) })
      end
    end
  end

  describe 'demo:connect_oca' do
    let!(:fake) do
      andreani = Service.create!(service_name: 'Andreani', type: 'courier', http_method: 'POST',
                                 uri: 'https://apis.andreani.com/v2/ordenes-de-envio',
                                 response_mapper: { 'numero' => 'tracking_number' })
      CompanyIntegration.create!(company: company, service: andreani,
                                 credentials: { 'access_token' => 'DEMO-TOKEN-ANDREANI' })
    end
    let!(:shipment) do
      in_company do
        order = Order.create!(company: company, customer_name: 'Juan Pérez')
        Shipment.create!(company: company, order: order, company_integration: fake,
                         status: 'delivered', tracking_number: 'AND-100000002',
                         shipping_label_url: 'https://apis.andreani.com/labels/AND-100000002.pdf')
      end
    end

    def oca
      CompanyIntegration.joins(:service).find_by!(company: company,
                                                  services: { service_name: 'OCA' })
    end

    before do
      allow($stdout).to receive(:puts)
      run('demo:connect_oca', 'norte')
    end

    it 'connects the public test account' do
      expect(oca.credentials).to include('usr' => 'test@oca.com.ar')
    end

    it 'deactivates the example courier' do
      expect(fake.reload).not_to be_is_active
    end

    it 'moves the example shipments to OCA' do
      expect(shipment.reload).to have_attributes(company_integration_id: oca.id,
                                                 tracking_number: 'DEMO-OCA-100000002',
                                                 shipping_label_url: nil)
    end
  end
end
