# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Auth::RevokeToken, type: :poro do
  subject(:revoke) { described_class.new(user: user, authorization_header: header) }

  let(:company) { Company.create!(name: 'Acme', tax_id: '30-11111111-1') }
  let(:user) { User.create!(email: 'out@test.com', password: 'password123', company: company) }
  let(:token) { Warden::JWTAuth::UserEncoder.new.call(user, :user, nil).first }
  let(:header) { "Bearer #{token}" }

  def payload_of(raw)
    Warden::JWTAuth::TokenDecoder.new.call(raw)
  end

  it 'revokes the token it receives' do
    expect { revoke.call }.to change(JwtDenylist, :count).by(1)
  end

  it 'reports the revocation' do
    expect(revoke.call).to be(true)
  end

  it 'stores the jti of the token, not the user' do
    revoke.call

    expect(JwtDenylist.last.jti).to eq(payload_of(token)['jti'])
  end

  context 'without a usable token' do
    it 'reports failure when the header is empty' do
      expect(described_class.new(user: user, authorization_header: '').call).to be(false)
    end

    # Un token ilegible ya no autentica a nadie: el efecto buscado está cumplido
    # y no hay nada que revocar.
    it 'reports failure when the token cannot be decoded' do
      expect(described_class.new(user: user, authorization_header: 'Bearer nope').call).to be(false)
    end
  end

  # Dos logouts del mismo token en paralelo pasan los dos por el `find_by` de
  # `find_or_create_by!` sin encontrar nada, y chocan en el insert contra el
  # índice único de `jti`. Antes eso salía como 500.
  #
  # Para reproducirlo: la fila ya está insertada —el otro logout ganó— y se
  # reemplaza `find_or_create_by!` por el `create!` pelado que ejecuta cuando su
  # `find_by` no encuentra nada. La excepción la levanta el índice único de
  # PostgreSQL, no un doble; lo único simulado es que el find llegó tarde.
  context 'when another logout of the same token wins the race' do
    before do
      other = payload_of(token)
      JwtDenylist.create!(jti: other['jti'], exp: Time.zone.at(other['exp'].to_i))
      allow(JwtDenylist).to receive(:find_or_create_by!) { |attrs| JwtDenylist.create!(attrs) }
    end

    it 'does not raise' do
      expect { revoke.call }.not_to raise_error
    end

    it 'reports the revocation anyway, because the token did end up revoked' do
      expect(revoke.call).to be(true)
    end

    it 'leaves a single entry for the token' do
      revoke.call

      expect(JwtDenylist.where(jti: payload_of(token)['jti']).count).to eq(1)
    end
  end
end
