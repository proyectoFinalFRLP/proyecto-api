# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AccentInsensitiveSearch do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }

  around { |example| Current.set(company_id: company.id) { example.run } }

  def product(name) = Product.create!(company: company, sku: name.parameterize, name: name)

  it 'finds a word without its accents', :aggregate_failures do
    camion = product('Camión de juguete')
    product('Avión')

    expect(Product.matching_text(%i[name], 'camion')).to contain_exactly(camion)
    expect(Product.matching_text(%i[name], 'CAMIÓN')).to contain_exactly(camion)
  end

  it 'matches any of the columns' do
    found = product('Sensor')

    expect(Product.matching_text(%i[sku name], 'sens')).to contain_exactly(found)
  end

  it 'returns everything for a blank term' do
    product('Sensor')

    expect(Product.matching_text(%i[name], '  ').count).to eq(1)
  end

  # Un `_` tipeado es texto, no el comodín de "un carácter cualquiera".
  it 'searches a typed wildcard literally' do
    product('ab')

    expect(Product.matching_text(%i[name], '_b')).to be_empty
  end

  # Las columnas se interpolan en el SQL: nunca pueden venir de afuera.
  it 'refuses a column the model does not have' do
    expect { Product.matching_text(['name; DROP TABLE products'], 'x') }
      .to raise_error(ArgumentError, /unknown search columns/)
  end
end
