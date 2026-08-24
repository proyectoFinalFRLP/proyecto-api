# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Webhooks::RetryFailedEventJob, type: :job do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:event) do
    FailedEvent.create!(company: company, event_type: 'integrations.http_request',
                        status: :pending, next_retry_at: 1.minute.ago)
  end
  let(:retrier) { instance_double(Webhooks::RetryFailedEvent, call: true) }

  before { allow(Webhooks::RetryFailedEvent).to receive(:new).and_return(retrier) }

  def run = described_class.new.perform(event.id, company.id)

  it 'claims the event so no other worker picks it up' do
    run

    expect(event.reload.status).to eq('processing')
  end

  it 'stamps the claim so an abandoned event can be rescued later' do
    run

    expect(event.reload.claimed_at).to be_within(5.seconds).of(Time.current)
  end

  it 'delegates the attempt to the retry PORO' do
    run

    expect(retrier).to have_received(:call)
  end

  it 'ignores an event that belongs to another tenant' do
    other = Company.create!(name: 'Other', tax_id: '30-99999999-9')
    described_class.new.perform(event.id, other.id)

    expect(event.reload.status).to eq('pending')
  end

  context 'when a previous worker died holding the claim' do
    before { event.update!(status: :processing, claimed_at: 10.minutes.ago) }

    it 'takes the event over instead of leaving it stuck' do
      run

      expect(retrier).to have_received(:call)
    end

    it 'refreshes the claim' do
      run

      expect(event.reload.claimed_at).to be_within(5.seconds).of(Time.current)
    end
  end

  context 'when the event was already claimed by another worker' do
    before { event.update!(status: :processing, claimed_at: 1.minute.ago) }

    it 'does nothing' do
      run

      expect(Webhooks::RetryFailedEvent).not_to have_received(:new)
    end
  end

  context 'when two workers race for the same event' do
    it 'lets only one of them run the attempt' do
      2.times { run }

      expect(Webhooks::RetryFailedEvent).to have_received(:new).once
    end
  end

  context 'when the event no longer exists' do
    it 'does not raise' do
      event.destroy!

      expect { run }.not_to raise_error
    end
  end
end
