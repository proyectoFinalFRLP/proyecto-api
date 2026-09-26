# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Shipments::ScanPullTrackingJob, type: :job do
  include ActiveSupport::Testing::TimeHelpers

  let(:company_a) { Company.create!(name: 'Tenant A', tax_id: '30-11111111-1') }
  let(:courier) do
    courier_service('Correo', tracking_service: tracking_template('Correo - Seguimiento'))
  end

  # Sin microsegundos: el matcher de `at` compara con precisión de segundo.
  around { |example| travel_to(Time.current.change(usec: 0)) { example.run } }

  def tracking_template(name, batch: false)
    mapper = if batch
               { 'envios[].numero' => 'tracking_number', 'envios[].estado' => 'external_status' }
             else
               { 'estado' => 'external_status' }
             end
    uri = batch ? 'https://correo.test/tracking' : 'https://correo.test/tracking/:tracking_number'
    courier_service(name, http_method: 'GET', uri: uri, response_mapper: mapper)
  end

  # El tenant se activa sólo para crear: CompanyScoped fuerza el company_id del
  # contexto, y el barrido tiene que encontrar envíos de varias empresas.
  def integration_for(company, service: courier, **attrs)
    Current.company_id = company.id
    courier_integration(company: company, service: service, **attrs)
  ensure
    Current.reset
  end

  def shipment_for(integration, tracking, status: 'in_transit')
    Current.company_id = integration.company_id
    order = Order.create!(company_id: integration.company_id, customer_name: 'Juan', status: 'paid')
    Shipment.create!(company_id: integration.company_id, company_integration: integration,
                     order: order, tracking_number: tracking, status: status)
  ensure
    Current.reset
  end

  def company_b = @company_b ||= Company.create!(name: 'Tenant B', tax_id: '30-22222222-2')

  def run = described_class.new.perform

  context 'with a courier that answers one shipment per request' do
    let(:integration) { integration_for(company_a) }
    let!(:first) { shipment_for(integration, 'CA-1') }
    let!(:second) { shipment_for(integration, 'CA-2', status: 'ready_to_ship') }

    it 'enqueues one job per in-flight shipment with its tenant', :aggregate_failures do
      expect { run }.to have_enqueued_job(Shipments::PollTrackingJob)
        .with(integration.id, [first.id], company_a.id)
      expect(Shipments::PollTrackingJob)
        .to have_been_enqueued.with(integration.id, [second.id], company_a.id)
    end

    it 'staggers the requests to the same courier', :aggregate_failures do
      run
      expect(Shipments::PollTrackingJob).to have_been_enqueued
        .with(integration.id, [first.id], company_a.id).at(Time.current)
      expect(Shipments::PollTrackingJob).to have_been_enqueued
        .with(integration.id, [second.id], company_a.id).at(2.seconds.from_now)
    end

    it 'does not poll delivered shipments' do
      shipment_for(integration, 'CA-3', status: 'delivered')
      expect { run }.to have_enqueued_job(Shipments::PollTrackingJob).twice
    end

    it 'shrinks the gap when the round would not fit before the next cycle' do
      stub_const("#{described_class}::WINDOW", 2.seconds)
      run
      expect(Shipments::PollTrackingJob).to have_been_enqueued
        .with(integration.id, [second.id], company_a.id).at(1.second.from_now)
    end
  end

  context 'with a courier that answers many shipments per request' do
    let(:batch_courier) do
      courier_service('Correo masivo', tracking_service: tracking_template('Masivo', batch: true))
    end
    let(:integration) { integration_for(company_a, service: batch_courier) }
    let!(:shipments) { %w[CB-1 CB-2 CB-3].map { |number| shipment_for(integration, number) } }

    it 'enqueues a single job for all of them' do
      expect { run }.to have_enqueued_job(Shipments::PollTrackingJob)
        .with(integration.id, shipments.map(&:id), company_a.id).exactly(:once)
    end

    it 'splits them in batches of the allowed size' do
      stub_const("#{described_class}::BATCH_SIZE", 2)
      expect { run }.to have_enqueued_job(Shipments::PollTrackingJob).twice
    end
  end

  it 'sweeps the shipments of every tenant' do
    shipment_for(integration_for(company_a), 'CA-1')
    other = shipment_for(integration_for(company_b), 'CA-2')

    expect { run }.to have_enqueued_job(Shipments::PollTrackingJob)
      .with(other.company_integration_id, [other.id], company_b.id)
  end

  # Una integración con plantilla de seguimiento y sin nada en vuelo: el barrido
  # la encuentra y tiene que salir sin encolar. Sin este ejemplo, dividir por la
  # cantidad de grupos con la lista vacía —una división por cero— no la veía
  # nadie (TESIS-93).
  it 'enqueues nothing for a courier with no shipment in flight' do
    integration_for(company_a)

    expect { run }.not_to have_enqueued_job(Shipments::PollTrackingJob)
  end

  it 'still sweeps the couriers that do have shipments in flight' do
    integration_for(company_a)
    other = shipment_for(integration_for(company_b), 'CB-1')

    expect { run }.to have_enqueued_job(Shipments::PollTrackingJob)
      .with(other.company_integration_id, [other.id], company_b.id)
  end

  it 'ignores couriers without a tracking template' do
    shipment_for(integration_for(company_a, service: courier_service('Andreani')), 'AND-1')
    expect { run }.not_to have_enqueued_job(Shipments::PollTrackingJob)
  end

  it 'ignores inactive integrations' do
    shipment_for(integration_for(company_a, is_active: false), 'CA-1')
    expect { run }.not_to have_enqueued_job(Shipments::PollTrackingJob)
  end

  context 'when a tenant context leaked from a previous job' do
    it 'still sweeps the shipments of every tenant' do
      other = shipment_for(integration_for(company_b), 'CA-2')
      Current.company_id = company_a.id

      expect { run }.to have_enqueued_job(Shipments::PollTrackingJob)
        .with(other.company_integration_id, [other.id], company_b.id)
    end
  end

  it 'is scheduled in every environment that runs recurring tasks', :aggregate_failures do
    schedule = YAML.load_file(Rails.root.join('config/recurring.yml'), aliases: true)

    %w[development production].each do |env|
      expect(schedule.dig(env, 'poll_courier_tracking', 'class')).to eq(described_class.name)
    end
  end
end
