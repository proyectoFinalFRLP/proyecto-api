# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AdminUser, type: :model do
  subject(:admin_user) { described_class.new(email: 'admin@backoffice.com', password: 'admin123') }

  it 'is valid with email and password' do
    expect(admin_user).to be_valid
  end

  it 'is invalid without an email' do
    admin_user.email = nil
    expect(admin_user).not_to be_valid
  end

  it 'is invalid with a short password' do
    admin_user.password = '123'
    expect(admin_user).not_to be_valid
  end

  it 'enforces email uniqueness' do
    admin_user.save!
    duplicate = described_class.new(email: admin_user.email, password: 'otra-clave-123')
    expect(duplicate).not_to be_valid
  end

  it 'authenticates with a valid password' do
    admin_user.save!
    expect(admin_user.valid_password?('admin123')).to be(true)
  end
end
