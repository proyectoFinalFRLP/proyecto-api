# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/seeds/oca').to_s

# El cron de la demo: no hace nada salvo que el entorno lo habilite, y sólo con
# la empresa que nombra.
RSpec.describe Demo::RealActivityJob do
  let(:company) { Company.create!(name: 'Norte', tax_id: '30-11111111-1', slug: 'norte') }
  let(:result) { Demo::GenerateRealActivity::Result.new(skipped: nil, outcomes: [], warnings: []) }
  let(:generator) { instance_double(Demo::GenerateRealActivity, call: result) }

  around do |example|
    previous = ENV.to_h.slice('DEMO_ACTIVITY_COMPANY', 'DEMO_ACTIVITY_UNTIL')
    example.run
  ensure
    %w[DEMO_ACTIVITY_COMPANY DEMO_ACTIVITY_UNTIL].each { |name| ENV[name] = previous[name] }
  end

  before do
    ENV['DEMO_ACTIVITY_COMPANY'] = nil
    ENV['DEMO_ACTIVITY_UNTIL'] = nil
    company
    allow(Demo::GenerateRealActivity).to receive(:new).and_return(generator)
  end

  def perform(*) = described_class.perform_now(*)

  it 'does nothing by default' do
    perform

    expect(Demo::GenerateRealActivity).not_to have_received(:new)
  end

  it 'generates between 2 and 4 orders for the enabled company' do
    ENV['DEMO_ACTIVITY_COMPANY'] = 'norte'

    perform

    expect(Demo::GenerateRealActivity).to have_received(:new)
      .with(company: company, count: be_between(2, 4))
  end

  it 'takes the count of the recurring task when it has one' do
    ENV['DEMO_ACTIVITY_COMPANY'] = 'norte'

    perform(6)

    expect(Demo::GenerateRealActivity).to have_received(:new).with(company: company, count: 6)
  end

  it 'never touches another company' do
    Company.create!(name: 'Sur', tax_id: '30-22222222-2', slug: 'sur')
    ENV['DEMO_ACTIVITY_COMPANY'] = 'norte'

    perform

    expect(Demo::GenerateRealActivity).to have_received(:new).once.with(hash_including(company: company))
  end

  it 'does nothing and says so when the slug is unknown', :aggregate_failures do
    ENV['DEMO_ACTIVITY_COMPANY'] = 'nadie'
    allow(Rails.logger).to receive(:warn)

    perform

    expect(Demo::GenerateRealActivity).not_to have_received(:new)
    expect(Rails.logger).to have_received(:warn).with(/no company with slug nadie/)
  end

  context 'with an end date' do
    before { ENV['DEMO_ACTIVITY_COMPANY'] = 'norte' }

    it 'still runs on the last day' do
      ENV['DEMO_ACTIVITY_UNTIL'] = Time.find_zone!(described_class::ZONE).today.iso8601

      perform

      expect(Demo::GenerateRealActivity).to have_received(:new)
    end

    it 'stops after it' do
      ENV['DEMO_ACTIVITY_UNTIL'] = '2026-01-01'

      perform

      expect(Demo::GenerateRealActivity).not_to have_received(:new)
    end

    it 'stops when the date cannot be read' do
      ENV['DEMO_ACTIVITY_UNTIL'] = 'noviembre'

      perform

      expect(Demo::GenerateRealActivity).not_to have_received(:new)
    end
  end

  # Con la generación real: sin OCA conectada no se crea nada.
  context 'when the company has no OCA integration' do
    before do
      allow(Demo::GenerateRealActivity).to receive(:new).and_call_original
      ENV['DEMO_ACTIVITY_COMPANY'] = 'norte'
      OcaSeeds.install!
    end

    it 'creates no order', :aggregate_failures do
      allow(Rails.logger).to receive(:info)

      expect { perform }.not_to(change { Order.unscoped.count })
      expect(Rails.logger).to have_received(:info).with(/skipped, Norte no tiene una integración/)
    end
  end
end
