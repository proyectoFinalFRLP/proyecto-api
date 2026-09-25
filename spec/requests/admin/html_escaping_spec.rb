# frozen_string_literal: true

require 'rails_helper'

# Nombres y direcciones los cargan las empresas, o llegan por webhook desde una
# plataforma externa, y el backoffice los muestra a quien ve todas las
# empresas. Tienen que verse como texto y no ejecutarse (QA de TESIS-129).
RSpec.describe 'Company-loaded data in the backoffice (Avo)', type: :request do
  let(:script) { '<script>alert(1)</script>' }
  let(:image) { '<img src=x onerror=alert(2)>' }
  let(:company) { Company.create!(name: "Acme #{script}", tax_id: '20-11111111-1', slug: 'acme') }
  let!(:warehouse) do
    Warehouse.create!(company:, name: script, address: image, zip_code: '1900')
  end
  let!(:order) do
    Order.create!(company:, customer_name: script, customer_address: image, status: 'pending')
  end

  before { sign_in AdminUser.create!(email: 'admin@backoffice.com', password: 'admin123') }

  def expect_rendered_as_text(path, payloads = [script, image])
    get path

    aggregate_failures do
      expect(response).to have_http_status(:ok)
      payloads.each do |payload|
        expect(response.body).not_to include(payload)
        expect(response.body).to include(ERB::Util.html_escape(payload))
      end
    end
  end

  it 'escapes the company name in the list of companies' do
    expect_rendered_as_text('/admin/resources/companies', [script])
  end

  it 'escapes the warehouse in the list and in the detail', :aggregate_failures do
    expect_rendered_as_text('/admin/resources/warehouses')
    expect_rendered_as_text("/admin/resources/warehouses/#{warehouse.id}")
  end

  it 'escapes the customer of the order in the list and in the detail', :aggregate_failures do
    expect_rendered_as_text('/admin/resources/orders')
    expect_rendered_as_text("/admin/resources/orders/#{order.id}")
  end

  it 'escapes the data in the edit forms', :aggregate_failures do
    expect_rendered_as_text("/admin/resources/warehouses/#{warehouse.id}/edit")
    expect_rendered_as_text("/admin/resources/orders/#{order.id}/edit")
  end
end
