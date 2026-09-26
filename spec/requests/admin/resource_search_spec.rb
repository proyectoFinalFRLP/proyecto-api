# frozen_string_literal: true

require 'rails_helper'

# La búsqueda de los listados del backoffice. Encontrado en la QA de
# TESIS-129: en empresas, usuarios y productos respondía 500, porque el lambda
# usaba `search_term` y Avo 4 le pasa el texto buscado como `q`.
RSpec.describe 'Search in the backoffice lists (Avo)', type: :request do
  let(:acme) { Company.create!(name: 'Acme', tax_id: '20-11111111-1', slug: 'acme') }
  let(:globex) { Company.create!(name: 'Globex', tax_id: '20-22222222-2', slug: 'globex') }

  before { sign_in AdminUser.create!(email: 'admin@backoffice.com', password: 'admin123') }

  def expect_search(path, term, found:, left_out:)
    get path, params: { q: term }

    aggregate_failures do
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(found)
      expect(response.body).not_to include(left_out)
    end
  end

  it 'finds companies by name' do
    acme
    globex

    expect_search('/admin/resources/companies', 'acm', found: 'Acme', left_out: 'Globex')
  end

  it 'finds users by email' do
    User.create!(email: 'ana@acme.com', password: 'password123', company: acme)
    User.create!(email: 'beto@globex.com', password: 'password123', company: globex)

    expect_search('/admin/resources/users', 'ana@', found: 'ana@acme.com', left_out: 'beto@globex.com')
  end

  it 'finds products by SKU' do
    Product.create!(company: acme, sku: 'ACM-001', name: 'Router')
    Product.create!(company: globex, sku: 'GLX-001', name: 'Switch')

    expect_search('/admin/resources/products', 'acm-', found: 'Router', left_out: 'Switch')
  end
end
