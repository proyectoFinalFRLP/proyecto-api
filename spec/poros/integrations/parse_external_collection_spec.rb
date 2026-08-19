# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Integrations::ParseExternalCollection, type: :poro do
  subject(:parsed) { described_class.new(service: service, payload: payload).call }

  let(:mapper) do
    { 'id' => 'external_order_id',
      'order_items[].item.id' => 'external_product_id',
      'order_items[].quantity' => 'quantity' }
  end
  let(:service) do
    Service.create!(service_name: 'Mercado Libre', type: 'ecommerce', http_method: 'GET',
                    uri: 'https://api.ml.test/orders', response_mapper: mapper,
                    response_value_mapper: { 'unidad' => 'unit' })
  end
  let(:payload) do
    { 'id' => 'ML-1',
      'order_items' => [{ 'item' => { 'id' => 'MLA-1' }, 'quantity' => 2 },
                        { 'item' => { 'id' => 'MLA-2' }, 'quantity' => 1 }] }
  end

  it 'returns one row per element of the collection' do
    expect(parsed).to eq(
      [{ 'external_product_id' => 'MLA-1', 'quantity' => 2 },
       { 'external_product_id' => 'MLA-2', 'quantity' => 1 }]
    )
  end

  it 'ignores the scalar entries of the mapper' do
    expect(parsed.first).not_to have_key('external_order_id')
  end

  context 'when the template declares no collection' do
    let(:mapper) { { 'id' => 'external_order_id' } }

    it 'returns an empty list' do
      expect(parsed).to eq([])
    end
  end

  context 'when the payload does not carry the collection' do
    let(:payload) { { 'id' => 'ML-1' } }

    it 'returns an empty list instead of raising' do
      expect(parsed).to eq([])
    end
  end

  context 'when the platform sends a single item as an object' do
    let(:payload) { { 'order_items' => { 'item' => { 'id' => 'MLA-1' }, 'quantity' => 3 } } }

    it 'processes it as a one-element collection' do
      expect(parsed).to eq([{ 'external_product_id' => 'MLA-1', 'quantity' => 3 }])
    end
  end

  context 'when an element has none of the mapped keys' do
    let(:payload) { { 'order_items' => [{ 'unrelated' => 1 }] } }

    it 'drops it instead of returning an empty row' do
      expect(parsed).to eq([])
    end
  end

  context 'when the collection hangs from a nested node' do
    let(:mapper) { { 'order.items[].sku' => 'external_product_id' } }
    let(:payload) { { 'order' => { 'items' => [{ 'sku' => 'A-1' }] } } }

    it 'resolves the root path before splitting the elements' do
      expect(parsed).to eq([{ 'external_product_id' => 'A-1' }])
    end
  end

  context 'when the element itself is the value' do
    let(:mapper) { { 'skus[]' => 'external_product_id' } }
    let(:payload) { { 'skus' => %w[A-1 A-2] } }

    it 'maps each element without a path inside it' do
      expect(parsed).to eq(
        [{ 'external_product_id' => 'A-1' }, { 'external_product_id' => 'A-2' }]
      )
    end
  end

  context 'when an element value has a translation in the value mapper' do
    let(:mapper) { { 'order_items[].unit' => 'unit' } }
    let(:payload) { { 'order_items' => [{ 'unit' => 'unidad' }] } }

    it 'translates it like any other mapped value' do
      expect(parsed).to eq([{ 'unit' => 'unit' }])
    end
  end
end
