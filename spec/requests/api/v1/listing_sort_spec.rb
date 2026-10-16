# frozen_string_literal: true

require 'rails_helper'

# Orden por columna de los listados (TESIS-184, Api::V1::Sortable). Lo que se
# prueba es el contrato que usa el front: el listado entero sale ordenado por
# la clave pedida, en las dos direcciones; los vacíos van al final; los empates
# no saltan de lugar entre páginas; y una clave inventada no rompe nada.
RSpec.describe 'Listing sort', type: :request do
  let(:company) { Company.create!(name: 'Tenant A', tax_id: '30-11111111-1') }
  let(:user) { User.create!(email: 'a@example.com', password: 'password123', company: company) }
  let(:headers) { auth_headers(user) }
  let(:warehouse) do
    Warehouse.create!(company: company, name: 'Central', zip_code: '1900', address: 'Calle 1')
  end

  def auth_headers(user)
    post '/api/v1/auth/login', params: { email: user.email, password: 'password123' },
                               headers: { 'X-Tenant-Slug' => user.company.slug }
    { 'Authorization' => "Bearer #{response.parsed_body['token']}" }
  end

  def listed(path, field, **params)
    get path, params: params, headers: headers
    response.parsed_body['data'].pluck(field)
  end

  describe 'GET /api/v1/orders' do
    def order(name, total:, status: 'pending', created_at: Time.current)
      Order.create!(company: company, customer_name: name, total_amount: total, status: status,
                    created_at: created_at)
    end

    before do
      order('Ana', total: 300, status: 'paid', created_at: 3.days.ago)
      order('Beto', total: 100, status: 'cancelled', created_at: 2.days.ago)
      order('Cora', total: nil, created_at: 1.day.ago)
    end

    it 'sorts the whole listing by total, both ways, with the empty total last',
       :aggregate_failures do
      expect(listed('/api/v1/orders', 'customer_name', sort: 'total', direction: 'asc'))
        .to eq(%w[Beto Ana Cora])
      expect(listed('/api/v1/orders', 'customer_name', sort: 'total', direction: 'desc'))
        .to eq(%w[Ana Beto Cora])
    end

    it 'sorts the status by its lifecycle, not alphabetically' do
      expect(listed('/api/v1/orders', 'customer_name', sort: 'status', direction: 'asc'))
        .to eq(%w[Cora Ana Beto])
    end

    def ship(name, courier)
      Shipment.create!(company: company, order: Order.find_by(customer_name: name),
                       company_integration: courier_integration(company: company, name: courier))
    end

    it 'sorts by the courier of the shipment, the ones without one last' do
      ship('Ana', 'OCA')
      ship('Beto', 'Andreani')

      expect(listed('/api/v1/orders', 'customer_name', sort: 'courier', direction: 'asc'))
        .to eq(%w[Beto Ana Cora])
    end

    it 'keeps the newest first when the key is unknown' do
      expect(listed('/api/v1/orders', 'customer_name', sort: 'password', direction: 'asc'))
        .to eq(%w[Cora Beto Ana])
    end

    it 'keeps the newest first when the direction is unknown' do
      expect(listed('/api/v1/orders', 'customer_name', sort: 'total', direction: 'sideways'))
        .to eq(%w[Cora Beto Ana])
    end

    it 'answers 400 for a sort that is not a single value' do
      get '/api/v1/orders', params: { sort: %w[total status] }, headers: headers
      expect(response).to have_http_status(:bad_request)
    end

    # Cinco órdenes con el mismo estado, en páginas de dos: sin desempate por id
    # el motor puede devolverlas en cualquier orden entre una consulta y otra.
    it 'does not repeat or skip rows across pages when the values tie' do
      %w[Dani Eli].each { |name| order(name, total: 50) }
      pages = (1..3).flat_map do |page|
        listed('/api/v1/orders', 'id', sort: 'status', direction: 'asc', per_page: 2, page: page)
      end

      expect(pages).to match_array(Order.pluck(:id))
    end
  end

  describe 'GET /api/v1/shipments' do
    def shipment(name, cost:, status: 'pending')
      Shipment.create!(company: company, status: status, shipping_cost: cost,
                       order: Order.create!(company: company, customer_name: name))
    end

    before do
      shipment('Ana', cost: 2_000, status: 'delivered')
      shipment('Beto', cost: nil, status: 'pending')
      shipment('Cora', cost: 500, status: 'in_transit')
    end

    it 'sorts by cost, the shipment without a quote last in both directions',
       :aggregate_failures do
      expect(listed('/api/v1/shipments', 'shipping_cost', sort: 'shipping_cost', direction: 'asc'))
        .to eq([500.0, 2000.0, nil])
      expect(listed('/api/v1/shipments', 'shipping_cost', sort: 'shipping_cost',
                                                          direction: 'desc'))
        .to eq([2000.0, 500.0, nil])
    end

    it 'sorts the status by the lifecycle of a shipment' do
      expect(listed('/api/v1/shipments', 'status', sort: 'status', direction: 'asc'))
        .to eq(%w[pending in_transit delivered])
    end
  end

  describe 'GET /api/v1/products' do
    def stocked(sku, quantity, name: sku)
      Product.create!(company: company, sku: sku, name: name).tap do |product|
        Stock.create!(product: product, warehouse: warehouse, quantity: quantity)
      end
    end

    before do
      stocked('B-002', 5, name: 'Zócalo')
      stocked('A-001', 50, name: 'Mouse')
      stocked('C-003', 0, name: 'Cable')
    end

    it 'sorts by the available stock, an aggregate of every warehouse', :aggregate_failures do
      expect(listed('/api/v1/products', 'sku', sort: 'total_stock', direction: 'desc'))
        .to eq(%w[A-001 B-002 C-003])
      expect(listed('/api/v1/products', 'sku', sort: 'total_stock', direction: 'asc'))
        .to eq(%w[C-003 B-002 A-001])
    end

    it 'sorts by name and still filters by tab' do
      expect(listed('/api/v1/products', 'name', sort: 'name', direction: 'asc',
                                                status: 'out_of_stock'))
        .to eq(%w[Cable])
    end

    it 'sorts by sku' do
      expect(listed('/api/v1/products', 'sku', sort: 'sku', direction: 'asc'))
        .to eq(%w[A-001 B-002 C-003])
    end

    it 'still counts the whole filtered listing in meta' do
      get '/api/v1/products', params: { sort: 'total_stock', direction: 'asc' }, headers: headers
      expect(response.parsed_body.dig('meta', 'total')).to eq(3)
    end
  end

  describe 'GET /api/v1/warehouses' do
    before do
      warehouse
      Warehouse.create!(company: company, name: 'Norte', zip_code: '1100', address: 'Calle 2')
    end

    it 'sorts by zip code', :aggregate_failures do
      expect(listed('/api/v1/warehouses', 'name', sort: 'zip_code', direction: 'asc'))
        .to eq(%w[Norte Central])
      expect(listed('/api/v1/warehouses', 'name', sort: 'zip_code', direction: 'desc'))
        .to eq(%w[Central Norte])
    end

    it 'sorts by the units stored, an aggregate of the warehouse' do
      product = Product.create!(company: company, sku: 'A-001', name: 'Mouse')
      Stock.create!(product: product, warehouse: warehouse, quantity: 10)

      expect(listed('/api/v1/warehouses', 'name', sort: 'stored_units', direction: 'desc'))
        .to eq(%w[Central Norte])
    end
  end

  describe 'GET /api/v1/failed-events' do
    def event(attempts, status)
      FailedEvent.create!(company: company, event_type: 'integrations.http_request',
                          attempts: attempts, status: status)
    end

    before do
      event(3, 'dead')
      event(1, 'pending')
      event(2, 'processing')
    end

    it 'sorts by attempts, both ways', :aggregate_failures do
      expect(listed('/api/v1/failed-events', 'attempts', sort: 'attempts', direction: 'asc'))
        .to eq([1, 2, 3])
      expect(listed('/api/v1/failed-events', 'attempts', sort: 'attempts', direction: 'desc'))
        .to eq([3, 2, 1])
    end

    it 'sorts the status by its lifecycle' do
      expect(listed('/api/v1/failed-events', 'status', sort: 'status', direction: 'asc'))
        .to eq(%w[pending processing dead])
    end
  end
end
