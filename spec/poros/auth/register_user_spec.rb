require 'rails_helper'

RSpec.describe Auth::RegisterUser, type: :poro do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-11111111-1', slug: 'acme') }
  let(:otra) { Company.create!(name: 'Otra', tax_id: '20-22222222-2', slug: 'otra') }

  def register(extra_params = {}, into: company)
    params = { email: 'a@test.com', password: 'password123' }.merge(extra_params)
    described_class.new(params: params, company: into).call
  end

  it 'creates the account under the given company', :aggregate_failures do
    user = register

    expect(user).to be_persisted
    expect(user.company).to eq(company)
  end

  # Registrarse es pedir acceso: la cuenta no entra hasta que la aprueben.
  it 'creates the account pending approval' do
    expect(register.approved).to be(false)
  end

  context 'when the email already has an account' do
    before { User.create!(email: 'a@test.com', password: 'password123', company: otra) }

    it 'creates nothing and returns nil', :aggregate_failures do
      result = nil

      expect { result = register }.not_to change(User, :count)
      expect(result).to be_nil
    end

    # El error de formato se informa igual que con un email libre, y sin
    # mencionar que el email ya existe.
    it 'still raises on invalid params, without saying the email is taken' do
      expect { register({ password: '123' }) }
        .to raise_error(ActiveRecord::RecordInvalid,
                        'Validation failed: Password is too short (minimum is 6 characters)')
    end
  end

  # Dos registros simultáneos del mismo email pasan los dos la validación y el
  # segundo choca contra el índice único: es un email que ya tenía cuenta.
  it 'treats a duplicate caught by the unique index as an existing email' do
    allow(User).to receive(:new).and_wrap_original do |original, *args|
      original.call(*args).tap { |user| allow(user).to receive(:save!).and_raise(ActiveRecord::RecordNotUnique) }
    end

    expect(register).to be_nil
  end

  # El company_id del body ya no llega hasta acá (el controller no lo permitea),
  # pero si llegara tampoco debe ganarle a la company resuelta por slug.
  it 'ignores a company_id passed in the params', :aggregate_failures do
    user = register({ company_id: otra.id })

    expect(user.company).to eq(company)
    expect(otra.users).to be_empty
  end

  # CompanyScoped pisa company_id con Current.company_id en el create. Si el
  # register llegara con un JWT de otro tenant en el header, el usuario tiene que
  # seguir cayendo en el tenant del slug.
  it 'wins over a Current.company_id of another tenant' do
    Current.company_id = otra.id

    expect(register.company).to eq(company)
  end

  it 'leaves Current untouched after the call' do
    Current.company_id = otra.id
    register

    expect(Current.company_id).to eq(otra.id)
  end

  it 'raises on invalid params' do
    expect { register({ email: '' }) }.to raise_error(ActiveRecord::RecordInvalid)
  end
end
