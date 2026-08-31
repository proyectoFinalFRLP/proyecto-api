# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Auth::PurgeExpiredTokensJob, type: :job do
  it 'deletes the entries whose token already expired' do
    JwtDenylist.create!(jti: SecureRandom.uuid, exp: 1.hour.ago)
    expect { described_class.new.perform }.to change(JwtDenylist, :count).by(-1)
  end

  it 'keeps the entries of tokens still alive' do
    JwtDenylist.create!(jti: SecureRandom.uuid, exp: 1.hour.from_now)
    expect { described_class.new.perform }.not_to change(JwtDenylist, :count)
  end

  # El barrido corre sin contexto de tenant: la revocacion es por token y la
  # tabla es global, como services.
  it 'runs with no tenant set' do
    Current.company_id = nil
    JwtDenylist.create!(jti: SecureRandom.uuid, exp: 1.hour.ago)
    expect { described_class.new.perform }.to change(JwtDenylist, :count).by(-1)
  end
end
