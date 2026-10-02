# frozen_string_literal: true

require 'rails_helper'

# Los seeds corren también en el entorno desplegado: el entrypoint del Dockerfile
# hace db:prepare, que siembra toda base nueva. Las contraseñas que el repo trae
# para desarrollo no pueden terminar ahí (TESIS-130, ADR-018).
RSpec.describe 'db/seeds.rb' do # rubocop:disable RSpec/DescribeClass
  let(:company_emails) do
    %w[admin@norte.com operador@norte.com admin@sur.com deposito@sur.com admin@vieja.com]
  end

  def run_seeds
    load Rails.root.join('db/seeds.rb')
  end

  def seeded_admin
    AdminUser.find_by!(email: 'admin@backoffice.com')
  end

  def password_of?(email, password)
    User.find_by!(email: email).valid_password?(password)
  end

  # El resumen del final; en la salida de los specs es ruido.
  before { allow($stdout).to receive(:puts) }

  around do |example|
    previous = ENV.to_h.slice('SEED_USER_PASSWORD', 'SEED_ADMIN_PASSWORD')
    example.run
    %w[SEED_USER_PASSWORD SEED_ADMIN_PASSWORD].each { |name| ENV[name] = previous[name] }
  end

  context 'when not in production' do
    it 'seeds the accounts with the development passwords', :aggregate_failures do
      run_seeds

      expect(password_of?('admin@norte.com', 'password123')).to be(true)
      expect(seeded_admin.valid_password?('admin123')).to be(true)
    end
  end

  context 'when in production' do
    let(:earlier_company) { Company.create!(name: 'Seeded before', tax_id: '30-99999999-9') }

    before do
      allow(Rails.env).to receive(:production?).and_return(true)
      ENV['SEED_USER_PASSWORD'] = 'users-password-from-env'
      ENV['SEED_ADMIN_PASSWORD'] = 'admin-password-from-env'
    end

    it 'creates every account with the passwords from the environment', :aggregate_failures do
      run_seeds

      users = User.where(email: company_emails)
      expect(users.size).to eq(company_emails.size)
      expect(users).to all(satisfy { |user| user.valid_password?('users-password-from-env') })
      expect(seeded_admin.valid_password?('admin-password-from-env')).to be(true)
    end

    it 'rotates the accounts a previous seed left with the repo passwords', :aggregate_failures do
      User.create!(email: 'admin@norte.com', password: 'password123', company: earlier_company)
      AdminUser.create!(email: 'admin@backoffice.com', password: 'admin123')

      run_seeds

      expect(password_of?('admin@norte.com', 'password123')).to be(false)
      expect(seeded_admin.valid_password?('admin123')).to be(false)
    end

    it 'leaves alone an account whose password was already changed' do
      User.create!(email: 'admin@sur.com', password: 'changed-by-the-operator', company: earlier_company)

      run_seeds

      expect(password_of?('admin@sur.com', 'changed-by-the-operator')).to be(true)
    end

    it 'refuses to seed without the passwords', :aggregate_failures do
      ENV['SEED_ADMIN_PASSWORD'] = nil

      expect { run_seeds }.to raise_error(RuntimeError, /SEED_ADMIN_PASSWORD/)
      expect(Company.count).to eq(0)
    end

    it 'refuses a password that lives in the repo', :aggregate_failures do
      ENV['SEED_USER_PASSWORD'] = 'password123'

      expect { run_seeds }.to raise_error(RuntimeError, /neither can be a password from the repo/)
      expect(User.count).to eq(0)
    end
  end
end
