# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Webhooks::RequeueFailedEvent, type: :poro do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:event) do
    FailedEvent.create!(company: company, event_type: 'integrations.http_request',
                        status: :dead, attempts: 5, next_retry_at: nil)
  end

  around do |example|
    original = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    example.run
    ActiveJob::Base.queue_adapter = original
  end

  before { Current.company_id = company.id }

  after { Current.reset }

  it 'brings a dead event back to the queue with a fresh budget', :aggregate_failures do
    described_class.new(failed_event: event).call

    expect(event.reload).to have_attributes(status: 'pending', attempts: 0)
    expect(event.next_retry_at).to be <= Time.current
  end

  it 'enqueues the retry immediately instead of waiting for the cronjob' do
    described_class.new(failed_event: event).call

    expect(enqueued_retries).to contain_exactly([event.id, company.id])
  end

  it 'requeues a discarded event' do
    event.update!(status: :discarded)

    expect(described_class.new(failed_event: event).call.status).to eq('pending')
  end

  it 'refuses to requeue an event that is already being processed' do
    event.update!(status: :processing)

    expect { described_class.new(failed_event: event).call }
      .to raise_error(described_class::NotRequeueable, /processing/)
  end

  it 'refuses to requeue an event that already succeeded' do
    event.update!(status: :succeeded)

    expect { described_class.new(failed_event: event).call }
      .to raise_error(described_class::NotRequeueable)
  end

  def enqueued_retries
    ActiveJob::Base.queue_adapter.enqueued_jobs
                   .select { |job| job[:job] == Webhooks::RetryFailedEventJob }
                   .map { |job| job[:args] }
  end
end
