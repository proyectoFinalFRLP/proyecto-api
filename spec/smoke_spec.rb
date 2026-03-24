require 'rails_helper'

RSpec.describe User, type: :model do
  it 'persists a user' do
    user = User.create(email: 'test@test.com', password: '123456')
    expect(User.count).to eq(1)
  end
end