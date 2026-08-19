# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FailedEvent, type: :model do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }

  def build_event(attributes = {})
    described_class.new({ company: company, event_type: 'integrations.http_request' }
                          .merge(attributes))
  end

  describe 'validations' do
    it 'is valid with the minimum attributes' do
      expect(build_event).to be_valid
    end

    it 'requires an event_type' do
      expect(build_event(event_type: nil)).not_to be_valid
    end

    it 'rejects an unknown status' do
      expect(build_event(status: 'exploded')).not_to be_valid
    end

    it 'rejects an unknown direction' do
      expect(build_event(direction: 'sideways')).not_to be_valid
    end

    it 'rejects a negative attempts counter' do
      expect(build_event(attempts: -1)).not_to be_valid
    end

    it 'defaults to a pending outbound event with five attempts' do
      event = build_event
      event.save!
      expect(event).to have_attributes(status: 'pending', direction: 'outbound',
                                       attempts: 0, max_attempts: 5)
    end
  end

  describe '.due' do
    let!(:overdue) do
      build_event(next_retry_at: 1.minute.ago).tap(&:save!)
    end

    before do
      build_event(next_retry_at: 1.hour.from_now).save!
      build_event(next_retry_at: 1.minute.ago, status: :dead).save!
      build_event(next_retry_at: 1.minute.ago, status: :succeeded).save!
      build_event(next_retry_at: 1.minute.ago, status: :processing).save!
    end

    it 'returns only pending events whose retry time already passed' do
      expect(described_class.due).to contain_exactly(overdue)
    end
  end

  describe '.stalled' do
    let!(:abandoned) do
      build_event(status: :processing, claimed_at: 10.minutes.ago).tap(&:save!)
    end

    before do
      build_event(status: :processing, claimed_at: 1.minute.ago).save!
      build_event(status: :pending, claimed_at: 10.minutes.ago).save!
    end

    it 'returns only the events whose claim already expired' do
      expect(described_class.stalled).to contain_exactly(abandoned)
    end
  end

  describe '.retryable' do
    it 'covers the due events and the abandoned claims', :aggregate_failures do
      overdue = build_event(next_retry_at: 1.minute.ago).tap(&:save!)
      abandoned = build_event(status: :processing, claimed_at: 10.minutes.ago).tap(&:save!)
      build_event(status: :processing, claimed_at: 1.minute.ago).save!
      build_event(next_retry_at: 1.hour.from_now).save!

      expect(described_class.retryable).to contain_exactly(overdue, abandoned)
    end
  end

  describe '.claimable' do
    it 'lets a worker take a pending event or an abandoned claim' do
      waiting = build_event(next_retry_at: 1.hour.from_now).tap(&:save!)
      abandoned = build_event(status: :processing, claimed_at: 10.minutes.ago).tap(&:save!)
      build_event(status: :processing, claimed_at: 1.minute.ago).save!
      build_event(status: :dead).save!

      expect(described_class.claimable).to contain_exactly(waiting, abandoned)
    end
  end

  describe '.next_retry_at' do
    # Cada intento duplica la espera: 1m, 2m, 4m, 8m, 16m (+ jitter).
    it 'schedules the first retry one base delay away' do
      expect(delay_for(0)).to be_between(base - 1, base + jitter + 1)
    end

    it 'schedules the fourth retry eight base delays away' do
      expect(delay_for(3)).to be_between((base * 8) - 1, (base * 8) + jitter + 1)
    end

    def delay_for(attempts) = described_class.next_retry_at(attempts) - Time.current
    def base = described_class::BASE_RETRY_DELAY
    def jitter = described_class::MAX_JITTER
  end

  describe '#attempts_exhausted?' do
    it 'is false while attempts remain' do
      expect(build_event(attempts: 4, max_attempts: 5)).not_to be_attempts_exhausted
    end

    it 'is true once the limit is reached' do
      expect(build_event(attempts: 5, max_attempts: 5)).to be_attempts_exhausted
    end
  end

  describe '#stalled?' do
    it 'is false for an event nobody claimed' do
      expect(build_event(status: :pending)).not_to be_stalled
    end

    it 'is false while the worker that claimed it is still within the timeout' do
      expect(build_event(status: :processing, claimed_at: 1.minute.ago)).not_to be_stalled
    end

    it 'is true once the claim outlived the timeout' do
      expect(build_event(status: :processing, claimed_at: 10.minutes.ago)).to be_stalled
    end
  end

  describe 'multi-tenancy' do
    let(:other_company) { Company.create!(name: 'Other', tax_id: '30-99999999-9') }

    it 'is scoped to the current tenant' do
      mine = build_event.tap(&:save!)
      described_class.new(company: other_company, event_type: 'x').save!

      Current.company_id = company.id
      expect(described_class.all).to contain_exactly(mine)
    end
  end
end
