# frozen_string_literal: true

require 'rails_helper'

# Alta y edición de usuarios de empresa desde el backoffice. Antes de TESIS-129
# el formulario no pedía password y crear un usuario fallaba siempre
# (hallazgo 3).
RSpec.describe 'Admin users (Avo)', type: :request do
  let(:admin_user) { AdminUser.create!(email: 'admin@backoffice.com', password: 'admin123') }
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-11111111-1', slug: 'acme') }
  let(:other_company) { Company.create!(name: 'Otra', tax_id: '20-22222222-2', slug: 'otra') }

  before { sign_in admin_user }

  def create_user(**attributes)
    post '/admin/resources/users', params: { user: {
      email: 'ana@acme.com', company_id: company.id,
      password: 'clave-segura', password_confirmation: 'clave-segura'
    }.merge(attributes) }
  end

  describe 'POST /admin/resources/users' do
    it 'creates the user with the password it was given', :aggregate_failures do
      expect { create_user }.to change(User, :count).by(1)
      expect(User.find_by(email: 'ana@acme.com').valid_password?('clave-segura')).to be(true)
    end

    it 'creates an account that can log in to the API' do
      create_user
      post '/api/v1/auth/login', params: { email: 'ana@acme.com', password: 'clave-segura' },
                                 headers: { 'X-Tenant-Slug' => company.slug }

      expect(response).to have_http_status(:ok)
    end

    it 'requires a password', :aggregate_failures do
      expect { create_user(password: '', password_confirmation: '') }.not_to change(User, :count)
      expect(response.body).to include('Password can&#39;t be blank')
    end

    it 'requires the confirmation to match the password' do
      expect { create_user(password_confirmation: 'otra-clave') }.not_to change(User, :count)
    end

    it 'requires a company' do
      expect { create_user(company_id: '') }.not_to change(User, :count)
    end

    it 'rejects an email that already has an account', :aggregate_failures do
      User.create!(email: 'ana@acme.com', password: 'password123', company: other_company)

      expect { create_user }.not_to change(User, :count)
      expect(response.body).to include('has already been taken')
    end
  end

  describe 'PATCH /admin/resources/users/:id' do
    let!(:user) { User.create!(email: 'ana@acme.com', password: 'password123', company:) }
    let(:user_path) { "/admin/resources/users/#{user.id}" }

    it 'keeps the password when the field is left blank', :aggregate_failures do
      patch user_path, params: { user: { email: 'ana.b@acme.com', password: '',
                                         password_confirmation: '' } }

      expect(user.reload.email).to eq('ana.b@acme.com')
      expect(user.valid_password?('password123')).to be(true)
    end

    it 'sets a new password' do
      patch user_path, params: { user: { password: 'nueva-clave',
                                         password_confirmation: 'nueva-clave' } }

      expect(user.reload.valid_password?('nueva-clave')).to be(true)
    end

    it 'does not move the user to another company', :aggregate_failures do
      patch user_path, params: { user: { email: 'ana.b@acme.com', company_id: other_company.id } }

      expect(user.reload.email).to eq('ana.b@acme.com')
      expect(user.company_id).to eq(company.id)
    end
  end
end
