# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Webhooks::RequeueFailedEvent, type: :poro do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:event) do
    FailedEvent.create!(company: company, event_type: 'integrations.http_request',
                        status: :dead, attempts: 5, next_retry_at: nil)
  end

  before { Current.company_id = company.id }

  it 'brings a dead event back to the queue with a fresh budget', :aggregate_failures do
    described_class.new(failed_event: event).call

    expect(event.reload).to have_attributes(status: 'pending', attempts: 0)
    expect(event.next_retry_at).to be <= Time.current
  end

  it 'enqueues the retry immediately instead of waiting for the cronjob' do
    expect { described_class.new(failed_event: event).call }
      .to have_enqueued_job(Webhooks::RetryFailedEventJob).with(event.id, company.id)
  end

  it 'requeues a discarded event' do
    event.update!(status: :discarded)

    expect(described_class.new(failed_event: event).call.status).to eq('pending')
  end

  it 'refuses to requeue an event a live worker is processing' do
    event.update!(status: :processing, claimed_at: 1.minute.ago)

    expect { described_class.new(failed_event: event).call }
      .to raise_error(described_class::NotRequeueable, /processing/)
  end

  it 'requeues an event whose worker died holding the claim', :aggregate_failures do
    event.update!(status: :processing, claimed_at: 10.minutes.ago)

    described_class.new(failed_event: event).call

    expect(event.reload).to have_attributes(status: 'pending', claimed_at: nil)
  end

  it 'refuses to requeue an event that already succeeded' do
    event.update!(status: :succeeded)

    expect { described_class.new(failed_event: event).call }
      .to raise_error(described_class::NotRequeueable)
  end
end
