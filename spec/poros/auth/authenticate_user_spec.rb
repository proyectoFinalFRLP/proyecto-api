require 'rails_helper'

RSpec.describe Auth::AuthenticateUser, type: :poro do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-11111111-1', slug: 'acme') }
  let(:otra) { Company.create!(name: 'Otra', tax_id: '20-22222222-2', slug: 'otra') }

  before { User.create!(email: 'log@test.com', password: 'password123', company: company) }

  it 'returns a token for valid credentials' do
    token = described_class.new(email: 'log@test.com', password: 'password123',
                                company: company).call
    expect(token).to be_present
  end

  it 'returns nil for a wrong password' do
    token = described_class.new(email: 'log@test.com', password: 'wrong', company: company).call
    expect(token).to be_nil
  end

  it 'returns nil for an unknown email' do
    token = described_class.new(email: 'ghost@test.com', password: 'password123',
                                company: company).call
    expect(token).to be_nil
  end

  # Credenciales correctas, tenant equivocado: no hay token. El email es único a
  # nivel global, así que sin el scope de company esto autenticaría.
  it 'returns nil for a user that belongs to another tenant' do
    token = described_class.new(email: 'log@test.com', password: 'password123',
                                company: otra).call
    expect(token).to be_nil
  end

  # El controller pasa el resultado de resolver el slug, que es nil cuando el
  # tenant no existe o está inactivo. El PORO no puede confundir eso con un
  # login global.
  it 'returns nil when the tenant could not be resolved' do
    token = described_class.new(email: 'log@test.com', password: 'password123', company: nil).call
    expect(token).to be_nil
  end

  # User incluye CompanyScoped: si el default scope se colara acá, un Current
  # heredado de otro request decidiría el tenant en vez del slug.
  it 'ignores a leftover Current.company_id and honours the given company' do
    Current.company_id = otra.id

    token = described_class.new(email: 'log@test.com', password: 'password123',
                                company: company).call

    expect(token).to be_present
  end
end
