# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Webhooks::DiscardFailedEvent, type: :poro do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:event) do
    FailedEvent.create!(company: company, event_type: 'integrations.http_request',
                        status: :dead, attempts: 5, next_retry_at: nil)
  end

  before { Current.company_id = company.id }

  it 'takes the event out of the retry cycle', :aggregate_failures do
    described_class.new(failed_event: event).call

    expect(event.reload).to have_attributes(status: 'discarded', next_retry_at: nil)
  end

  it 'returns the event' do
    expect(described_class.new(failed_event: event).call).to eq(event)
  end

  it 'releases the claim of an event discarded while it was being processed' do
    event.update!(status: :processing, claimed_at: 10.minutes.ago)

    described_class.new(failed_event: event).call

    expect(event.reload.claimed_at).to be_nil
  end
end
