require 'rails_helper'

RSpec.describe Auth::AuthenticateUser, type: :poro do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-11111111-1') }

  before { User.create!(email: 'log@test.com', password: 'password123', company: company) }

  it 'returns a token for valid credentials' do
    token = described_class.new(email: 'log@test.com', password: 'password123').call
    expect(token).to be_present
  end

  it 'returns nil for a wrong password' do
    token = described_class.new(email: 'log@test.com', password: 'wrong').call
    expect(token).to be_nil
  end

  it 'returns nil for an unknown email' do
    token = described_class.new(email: 'ghost@test.com', password: 'password123').call
    expect(token).to be_nil
  end
end
