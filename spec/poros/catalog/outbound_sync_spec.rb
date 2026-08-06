# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Catalog::OutboundSync, type: :poro do
  subject(:sync) { described_class.new(product: product) }

  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:product) { Product.create!(company: company, sku: 'SKU-001', name: 'Celular') }
  let(:warehouse) do
    Warehouse.create!(company: company, name: 'Central', zip_code: '1900', address: 'Calle 1')
  end

  # Plantilla de canal: el id externo viaja en la URI y el request_mapper
  # traduce la clave interna available_quantity a la que espera la plataforma.
  def create_service(name, host)
    Service.create!(service_name: name, type: 'ecommerce', http_method: 'PUT',
                    uri: "https://#{host}/items/:external_id",
                    request_mapper: { 'stock.quantity' => 'available_quantity' })
  end

  def publish_on(name, host, external_id, token: 'TOKEN', active: true)
    integration = CompanyIntegration.create!(company: company, service: create_service(name, host),
                                             credentials: { 'access_token' => token },
                                             is_active: active)
    ProductMapping.create!(product: product, company_integration: integration,
                           external_product_id: external_id)
  end

  def stub_channel(host, external_id, status: 200)
    stub_request(:put, "https://#{host}/items/#{external_id}")
      .to_return(status: status, body: '{}')
  end

  before { Stock.create!(product: product, warehouse: warehouse, quantity: 10) }

  context 'when the product is not published on any channel' do
    it 'finishes without raising' do
      expect { sync.call }.not_to raise_error
    end

    it 'does not reach any external API' do
      sync.call
      expect(a_request(:any, //)).not_to have_been_made
    end
  end

  context 'when the product is published on one channel' do
    before do
      publish_on('Mercado Libre', 'api.ml.test', 'MLA-1')
      stub_channel('api.ml.test', 'MLA-1')
    end

    it 'calls the channel on the external id of the mapping' do
      sync.call
      expect(a_request(:put, 'https://api.ml.test/items/MLA-1')).to have_been_made.once
    end

    it 'sends the stock consolidated across every warehouse' do
      north = Warehouse.create!(company: company, name: 'North', zip_code: '1901', address: 'C 2')
      Stock.create!(product: product, warehouse: north, quantity: 5)
      sync.call
      expect(WebMock).to have_requested(:put, 'https://api.ml.test/items/MLA-1')
        .with(body: { stock: { quantity: 15 } }.to_json)
    end

    it 'authenticates with the credentials of the integration' do
      sync.call
      expect(WebMock).to have_requested(:put, 'https://api.ml.test/items/MLA-1')
        .with(headers: { 'Authorization' => 'Bearer TOKEN' })
    end
  end

  context 'when the product is published on three channels' do
    before do
      publish_on('Mercado Libre', 'api.ml.test', 'MLA-1', token: 'ML-TOKEN')
      publish_on('Tiendanube', 'api.tn.test', 'TN-2', token: 'TN-TOKEN')
      publish_on('Shopify', 'api.shop.test', 'SH-3', token: 'SH-TOKEN')
      stub_channel('api.ml.test', 'MLA-1')
      stub_channel('api.tn.test', 'TN-2')
      stub_channel('api.shop.test', 'SH-3')
    end

    it 'fires one request per channel', :aggregate_failures do
      sync.call
      expect(a_request(:put, 'https://api.ml.test/items/MLA-1')).to have_been_made.once
      expect(a_request(:put, 'https://api.tn.test/items/TN-2')).to have_been_made.once
      expect(a_request(:put, 'https://api.shop.test/items/SH-3')).to have_been_made.once
    end

    it 'uses the credentials of each channel', :aggregate_failures do
      sync.call
      expect(WebMock).to have_requested(:put, 'https://api.tn.test/items/TN-2')
        .with(headers: { 'Authorization' => 'Bearer TN-TOKEN' })
      expect(WebMock).to have_requested(:put, 'https://api.shop.test/items/SH-3')
        .with(headers: { 'Authorization' => 'Bearer SH-TOKEN' })
    end
  end

  context 'when one channel fails' do
    before do
      publish_on('Mercado Libre', 'api.ml.test', 'MLA-1')
      publish_on('Tiendanube', 'api.tn.test', 'TN-2')
      stub_channel('api.ml.test', 'MLA-1', status: 500)
      stub_channel('api.tn.test', 'TN-2')
    end

    it 'still propagates to the healthy channels' do
      suppress(Integrations::AdapterExecutionError) { sync.call }
      expect(a_request(:put, 'https://api.tn.test/items/TN-2')).to have_been_made.once
    end

    it 'raises so the worker marks the job as failed' do
      expect { sync.call }.to raise_error(Integrations::AdapterExecutionError, /1 of 2 channels/)
    end

    it 'names the failing channel in the error' do
      expect { sync.call }.to raise_error(Integrations::AdapterExecutionError, /Mercado Libre/)
    end

    it 'aggregates every failing channel when they all fail' do
      stub_channel('api.tn.test', 'TN-2', status: 503)
      expect { sync.call }.to raise_error(Integrations::AdapterExecutionError, /2 of 2 channels/)
    end
  end

  context 'when a channel is deactivated' do
    before do
      publish_on('Mercado Libre', 'api.ml.test', 'MLA-1', active: false)
      publish_on('Tiendanube', 'api.tn.test', 'TN-2')
      stub_channel('api.tn.test', 'TN-2')
    end

    it 'does not send stock to the deactivated integration' do
      sync.call
      expect(a_request(:put, 'https://api.ml.test/items/MLA-1')).not_to have_been_made
    end

    it 'keeps syncing the active ones' do
      sync.call
      expect(a_request(:put, 'https://api.tn.test/items/TN-2')).to have_been_made.once
    end
  end
end
