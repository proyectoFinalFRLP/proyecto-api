require 'rails_helper'

RSpec.describe Auth::RegisterUser, type: :poro do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-11111111-1') }

  it 'creates a user under the given company', :aggregate_failures do
    user = described_class.new(
      params: { email: 'a@test.com', password: 'password123', company_id: company.id }
    ).call

    expect(user).to be_persisted
    expect(user.company).to eq(company)
  end

  it 'raises on invalid params' do
    expect do
      described_class.new(params: { email: '', password: 'password123', company_id: company.id }).call
    end.to raise_error(ActiveRecord::RecordInvalid)
  end
end
