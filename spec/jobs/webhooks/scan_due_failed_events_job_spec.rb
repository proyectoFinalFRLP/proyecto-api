# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Webhooks::ScanDueFailedEventsJob, type: :job do
  let(:company_a) { Company.create!(name: 'Tenant A', tax_id: '30-11111111-1') }
  let(:company_b) { Company.create!(name: 'Tenant B', tax_id: '30-22222222-2') }
  let!(:due_a) { create_event(company_a, next_retry_at: 1.minute.ago) }
  let!(:due_b) { create_event(company_b, next_retry_at: 1.hour.ago) }

  def create_event(company, attributes)
    FailedEvent.create!({ company: company,
                          event_type: 'integrations.http_request' }.merge(attributes))
  end

  def run = described_class.new.perform

  it 'enqueues a retry for the due event of a tenant' do
    expect { run }.to have_enqueued_job(Webhooks::RetryFailedEventJob).with(due_a.id, company_a.id)
  end

  it 'enqueues a retry for the due event of every other tenant' do
    expect { run }.to have_enqueued_job(Webhooks::RetryFailedEventJob).with(due_b.id, company_b.id)
  end

  it 'ignores events whose retry time has not arrived yet' do
    create_event(company_a, next_retry_at: 10.minutes.from_now)

    expect { run }.to have_enqueued_job(Webhooks::RetryFailedEventJob).twice
  end

  it 'ignores events that are no longer retryable' do
    create_event(company_a, next_retry_at: 1.minute.ago, status: :dead)
    create_event(company_a, next_retry_at: 1.minute.ago, status: :discarded)

    expect { run }.to have_enqueued_job(Webhooks::RetryFailedEventJob).twice
  end

  it 'ignores events already claimed by a live worker' do
    create_event(company_a, next_retry_at: 1.minute.ago, status: :processing,
                            claimed_at: 1.minute.ago)

    expect { run }.to have_enqueued_job(Webhooks::RetryFailedEventJob).twice
  end

  it 'rescues an event whose worker died holding the claim' do
    stalled = create_event(company_a, next_retry_at: 2.minutes.ago, status: :processing,
                                      claimed_at: 10.minutes.ago)

    expect { run }.to have_enqueued_job(Webhooks::RetryFailedEventJob)
      .with(stalled.id, company_a.id)
  end

  context 'when there are more events than the batch allows' do
    let!(:oldest) { create_event(company_a, next_retry_at: 2.hours.ago) }

    before { stub_const("#{described_class}::BATCH_SIZE", 1) }

    it 'attends the oldest event first' do
      expect { run }.to have_enqueued_job(Webhooks::RetryFailedEventJob)
        .with(oldest.id, company_a.id)
    end

    it 'leaves the rest for the next tick instead of re-scanning the same subset' do
      expect { run }.to have_enqueued_job(Webhooks::RetryFailedEventJob).exactly(:once)
    end
  end

  context 'when a tenant context leaked from a previous job' do
    before { Current.company_id = company_a.id }

    it 'still scans the events of every tenant' do
      expect { run }.to have_enqueued_job(Webhooks::RetryFailedEventJob)
        .with(due_b.id, company_b.id)
    end
  end
end
