# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Catalog::SyncStockToChannelsJob, type: :job do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:product) { Product.create!(company: company, sku: 'SKU-001', name: 'Celular') }
  let(:channel) do
    stub_request(:put, 'https://api.ml.test/items/MLA-1').to_return(status: 200, body: '{}')
  end

  def other_company
    @other_company ||= Company.create!(name: 'Otra', tax_id: '30-99999999-9')
  end

  # Producto con stock en un depósito y publicado en un canal externo.
  def publish_product_on_a_channel
    warehouse = Warehouse.create!(company: company, name: 'Central', zip_code: '1900',
                                  address: 'Calle 1')
    Stock.create!(product: product, warehouse: warehouse, quantity: 7)
    ProductMapping.create!(product: product, company_integration: integration,
                           external_product_id: 'MLA-1')
  end

  def integration
    service = Service.create!(service_name: 'Mercado Libre', type: 'ecommerce', http_method: 'PUT',
                              uri: 'https://api.ml.test/items/:external_id',
                              request_mapper: { 'available_quantity' => 'available_quantity' })
    CompanyIntegration.create!(company: company, service: service,
                               credentials: { 'access_token' => 'TOKEN' })
  end

  before do
    publish_product_on_a_channel
    channel
  end

  it 'runs on the low queue: outbound traffic does not compete with incoming events' do
    expect { described_class.perform_later(product.id, company.id) }
      .to have_enqueued_job.on_queue('low')
  end

  it 'pushes the consolidated stock to the mapped channel' do
    described_class.perform_now(product.id, company.id)
    expect(channel).to have_been_requested.once
  end

  it 'sends the stock the product has at execution time, not at enqueue time' do
    product.stocks.first.update!(quantity: 99)
    described_class.perform_now(product.id, company.id)
    expect(WebMock).to have_requested(:put, 'https://api.ml.test/items/MLA-1')
      .with(body: { available_quantity: 99 }.to_json)
  end

  it 'refuses to run without a tenant instead of syncing outside the scope' do
    expect { described_class.perform_now(product.id, nil) }
      .to raise_error(ArgumentError, /company_id is required/)
  end

  it 'does not reach the channels of a product from another company' do
    described_class.perform_now(product.id, other_company.id)
    expect(channel).not_to have_been_requested
  end

  context 'when the product no longer exists' do
    it 'exits silently instead of failing the job' do
      expect { described_class.perform_now(product.id + 1_000, company.id) }.not_to raise_error
    end

    it 'does not call any external API' do
      described_class.perform_now(product.id + 1_000, company.id)
      expect(channel).not_to have_been_requested
    end
  end

  context 'when a channel is down' do
    before { stub_request(:put, 'https://api.ml.test/items/MLA-1').to_return(status: 500) }

    it 'retries the job instead of losing the stock update' do
      expect { described_class.perform_now(product.id, company.id) }
        .to have_enqueued_job(described_class)
    end

    it 'leaves the internal stock untouched' do
      expect { described_class.perform_now(product.id, company.id) }
        .not_to(change { product.reload.total_stock })
    end
  end
end
