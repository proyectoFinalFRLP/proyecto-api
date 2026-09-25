require 'rails_helper'

RSpec.describe User, type: :model do
  subject(:user) { described_class.new(email: 'user@test.com', password: '123456', company: company) }

  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }

  it 'is valid with a company' do
    expect(user).to be_valid
  end

  it 'is invalid without a company' do
    user.company = nil
    expect(user).not_to be_valid
  end

  # Las cuentas que crean el backoffice, los seeds o la consola quedan
  # habilitadas. Sólo el registro público las crea sin aprobar.
  it 'is approved unless it is created as an access request' do
    expect(user.approved).to be(true)
  end

  it 'belongs to a company' do
    expect(described_class.reflect_on_association(:company).macro).to eq(:belongs_to)
  end
end
