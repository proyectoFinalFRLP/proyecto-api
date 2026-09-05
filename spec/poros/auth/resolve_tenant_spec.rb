require 'rails_helper'

RSpec.describe Auth::ResolveTenant, type: :poro do
  let(:norte) { Company.create!(name: 'Norte', tax_id: '20-11111111-1', slug: 'norte') }
  let(:sur) { Company.create!(name: 'Sur', tax_id: '20-22222222-2', slug: 'sur') }

  describe 'without a user' do
    it 'resolves an active company by slug' do
      expect(described_class.new(slug: norte.slug).call).to eq(norte)
    end

    it 'is case and whitespace insensitive' do
      norte

      expect(described_class.new(slug: '  NORTE ').call).to eq(norte)
    end

    it 'returns nil for an unknown slug' do
      expect(described_class.new(slug: 'no-existe').call).to be_nil
    end

    it 'returns nil for a blank slug' do
      expect(described_class.new(slug: '').call).to be_nil
    end

    it 'returns nil when no slug is given' do
      expect(described_class.new.call).to be_nil
    end

    it 'returns nil for an inactive company' do
      inactive = Company.create!(name: 'Vieja', tax_id: '20-33333333-3',
                                 slug: 'vieja', is_active: false)

      expect(described_class.new(slug: inactive.slug).call).to be_nil
    end
  end

  describe 'with a user' do
    let(:user) { User.create!(email: 'a@test.com', password: 'password123', company: norte) }

    it 'resolves the company of the user' do
      expect(described_class.new(user: user).call).to eq(norte)
    end

    # La regla dura: con sesión, el slug no puede mover el tenant.
    it 'ignores the slug entirely' do
      sur

      expect(described_class.new(slug: sur.slug, user: user).call).to eq(norte)
    end

    it 'returns nil when the company of the user is inactive' do
      norte.update!(is_active: false)

      expect(described_class.new(user: user).call).to be_nil
    end
  end
end
