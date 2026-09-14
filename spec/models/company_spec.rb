require 'rails_helper'

RSpec.describe Company, type: :model do
  subject(:company) { described_class.new(name: 'Acme', tax_id: '20-12345678-9') }

  it 'is valid with name and tax_id' do
    expect(company).to be_valid
  end

  it 'is invalid without a name' do
    company.name = nil
    expect(company).not_to be_valid
  end

  it 'is invalid without a tax_id' do
    company.tax_id = nil
    expect(company).not_to be_valid
  end

  it 'enforces tax_id uniqueness' do
    company.save!
    duplicate = described_class.new(name: 'Other', tax_id: company.tax_id)
    expect(duplicate).not_to be_valid
  end

  it 'defaults is_active to true' do
    company.save!
    expect(company.is_active).to be(true)
  end

  describe 'tenant config' do
    it 'defaults features and branding to empty hashes', :aggregate_failures do
      company.save!
      expect(company.features).to eq({})
      expect(company.branding).to eq({})
    end

    it 'stores features and branding as structured json' do
      company.update!(features: { 'integrations' => true },
                      branding: { 'primary_color' => '#2E7D32' })

      expect(company.reload.branding['primary_color']).to eq('#2E7D32')
    end
  end

  describe 'slug' do
    it 'keeps an explicit slug' do
      company.slug = 'acme'
      company.save!
      expect(company.slug).to eq('acme')
    end

    # Pedir el slug en cada alta sería ruido: los tenants que importan lo
    # declaran y el resto lo deriva del nombre.
    it 'derives one from the name when none is given' do
      company.save!
      expect(company.slug).to eq('acme')
    end

    it 'disambiguates a derived slug that is already taken' do
      described_class.create!(name: 'Acme', tax_id: '20-99999999-9')
      company.save!

      expect(company.slug).to eq('acme-2')
    end

    it 'enforces slug uniqueness' do
      company.save!
      duplicate = described_class.new(name: 'Other', tax_id: '20-99999999-9', slug: company.slug)

      expect(duplicate).not_to be_valid
    end

    # El slug es el subdominio del tenant, así que tiene que ser una etiqueta
    # DNS válida.
    it 'rejects a slug that is not a dns label' do
      company.slug = 'Not A Slug'
      expect(company).not_to be_valid
    end
  end

  describe '.find_active_by_slug' do
    it 'finds an active company' do
      company.update!(slug: 'acme')
      expect(described_class.find_active_by_slug('acme')).to eq(company)
    end

    it 'does not find an inactive one' do
      company.update!(slug: 'acme', is_active: false)
      expect(described_class.find_active_by_slug('acme')).to be_nil
    end

    it 'returns nil for a blank slug' do
      expect(described_class.find_active_by_slug(nil)).to be_nil
    end
  end

  describe 'associations' do
    it 'has many users' do
      expect(described_class.reflect_on_association(:users).macro).to eq(:has_many)
    end

    it 'has many warehouses' do
      expect(described_class.reflect_on_association(:warehouses).macro).to eq(:has_many)
    end

    it 'destroys dependent users and warehouses' do
      company.save!
      company.users.create!(email: 'a@a.com', password: '123456')
      company.warehouses.create!(name: 'Central', zip_code: '1900', address: 'Calle 1')

      expect { company.destroy }.to change(User, :count).by(-1).and change(Warehouse, :count).by(-1)
    end
  end
end
