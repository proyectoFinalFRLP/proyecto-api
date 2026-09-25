# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CompanyIntegrationPolicy, type: :policy do
  subject(:policy) { described_class.new(user, CompanyIntegration) }

  let(:company) do
    Company.create!(name: 'Tenant A', tax_id: '30-11111111-1', features: { 'integrations' => true })
  end
  let(:user) { User.create!(email: 'a@example.com', password: 'password123', company: company) }

  it 'lets a company with the integrations feature configure them' do
    expect(policy.update?).to be(true)
  end

  context 'when the company does not have the feature' do
    before { company.update!(features: { 'integrations' => false }) }

    it 'denies configuring them' do
      expect(policy.update?).to be(false)
    end
  end

  # Igual que el front (`features?.[feature] === true`): un "true" string es
  # apagado en los dos lados.
  context 'when the flag is not a real boolean' do
    before { company.update!(features: { 'integrations' => 'true' }) }

    it 'denies configuring them' do
      expect(policy.update?).to be(false)
    end
  end

  context 'without a user' do
    let(:user) { nil }

    it 'denies configuring them' do
      expect(policy.update?).to be(false)
    end
  end
end
