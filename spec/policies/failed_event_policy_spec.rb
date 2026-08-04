# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FailedEventPolicy, type: :policy do
  subject(:policy) { described_class.new(user, event) }

  let(:company) { Company.create!(name: 'Tenant A', tax_id: '30-11111111-1') }
  let(:user) { User.create!(email: 'a@example.com', password: 'password123', company: company) }
  let(:event) do
    FailedEvent.create!(company: company, event_type: 'integrations.http_request')
  end

  it 'lets an authenticated user list the events' do
    expect(policy.index?).to be(true)
  end

  it 'lets a user operate on an event of their own company', :aggregate_failures do
    expect(policy.show?).to be(true)
    expect(policy.requeue?).to be(true)
    expect(policy.discard?).to be(true)
  end

  context 'when the event belongs to another company' do
    let(:event) do
      other = Company.create!(name: 'Tenant B', tax_id: '30-22222222-2')
      FailedEvent.create!(company: other, event_type: 'integrations.http_request')
    end

    it 'denies every action on the record', :aggregate_failures do
      expect(policy.show?).to be(false)
      expect(policy.requeue?).to be(false)
      expect(policy.discard?).to be(false)
    end
  end

  context 'without a user' do
    let(:user) { nil }

    it 'denies listing' do
      expect(policy.index?).to be(false)
    end

    it 'denies operating on the record' do
      expect(policy.show?).to be(false)
    end
  end
end
