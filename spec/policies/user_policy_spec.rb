# frozen_string_literal: true

require 'rails_helper'

RSpec.describe UserPolicy, type: :policy do
  subject(:policy) { described_class.new(user, record) }

  let(:company) { Company.create!(name: 'Tenant A', tax_id: '30-11111111-1') }
  let(:user) { User.create!(email: 'a@example.com', password: 'password123', company: company) }
  let(:record) { user }

  it 'lets a user read their own identity' do
    expect(policy.show?).to be(true)
  end

  context 'when the record is a colleague of the same company' do
    let(:record) do
      User.create!(email: 'b@example.com', password: 'password123', company: company)
    end

    # Compartir empresa no alcanza: /me es la sesión, no un directorio.
    it 'denies reading them' do
      expect(policy.show?).to be(false)
    end
  end

  context 'without a user' do
    let(:user) { nil }
    let(:record) do
      User.create!(email: 'c@example.com', password: 'password123', company: company)
    end

    it 'denies reading' do
      expect(policy.show?).to be(false)
    end
  end
end
