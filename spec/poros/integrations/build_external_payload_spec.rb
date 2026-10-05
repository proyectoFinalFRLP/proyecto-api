# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Integrations::BuildExternalPayload, type: :poro do
  let(:service) do
    Service.create!(service_name: 'Moova', type: 'courier', uri: 'https://api.moova.io',
                    http_method: 'POST',
                    request_mapper: { 'destination.street' => 'customer_address',
                                      'status' => 'status' },
                    request_value_mapper: { 'paid' => 'pagado' })
  end

  it 'builds the nested external payload from the flat internal payload' do
    result = described_class.new(service: service, payload: { customer_address: 'Calle 1' }).call
    expect(result).to eq('destination' => { 'street' => 'Calle 1' })
  end

  it 'translates values through the request_value_mapper' do
    result = described_class.new(service: service, payload: { status: 'paid' }).call
    expect(result['status']).to eq('pagado')
  end

  it 'leaves values without translation untouched' do
    result = described_class.new(service: service, payload: { status: 'cancelled' }).call
    expect(result['status']).to eq('cancelled')
  end

  it 'skips mapped fields that are absent from the internal payload' do
    result = described_class.new(service: service, payload: { status: 'paid' }).call
    expect(result).not_to have_key('destination')
  end

  it 'ignores internal fields that are not in the mapper (whitelist)' do
    result = described_class.new(service: service, payload: { hacker_field: 'x' }).call
    expect(result).to eq({})
  end

  describe 'array segments in the mapper path' do
    let(:collection_service) do
      Service.create!(service_name: 'Andreani', type: 'courier',
                      uri: 'https://api.andreani.com', http_method: 'POST',
                      request_mapper: { 'bultos.0.sku' => 'sku', 'bultos.0.kilos' => 'weight' })
    end

    it 'builds an Array when the next path segment is a numeric index' do
      result = described_class.new(service: collection_service, payload: { sku: 'ABC' }).call
      expect(result).to eq('bultos' => [{ 'sku' => 'ABC' }])
    end

    it 'merges sibling fields into the same array element' do
      result = described_class.new(service: collection_service,
                                   payload: { sku: 'ABC', weight: 2 }).call
      expect(result).to eq('bultos' => [{ 'sku' => 'ABC', 'kilos' => 2 }])
    end

    it 'serializes the array as a JSON list, not as an object with numeric keys' do
      result = described_class.new(service: collection_service, payload: { sku: 'ABC' }).call
      expect(result.to_json).to eq('{"bultos":[{"sku":"ABC"}]}')
    end

    it 'supports a numeric index as the last segment' do
      collection_service.update!(request_mapper: { 'tags.0' => 'tag' })
      result = described_class.new(service: collection_service, payload: { tag: 'urgente' }).call
      expect(result).to eq('tags' => ['urgente'])
    end
  end

  # TESIS-138: datos de la cuenta y valores armados a partir de variables.
  describe 'settings and templates' do
    let(:graphql_service) do
      Service.create!(service_name: 'Shopify', type: 'ecommerce', http_method: 'POST',
                      uri: 'https://demo.myshopify.com/graphql.json',
                      request_mapper: { 'locationId' => 'settings.location_id',
                                        'id' => 'gid://shopify/ProductVariant/{{external_id}}',
                                        'quantity' => 'available_quantity' })
    end

    def build(payload, settings = {})
      described_class.new(service: graphql_service, payload: payload, settings: settings).call
    end

    it 'reads a settings.<key> value from the account settings, not from the payload' do
      result = build({ location_id: 'from-payload' }, { 'location_id' => 'gid://shopify/Location/7' })
      expect(result['locationId']).to eq('gid://shopify/Location/7')
    end

    it 'builds a value from a template with payload variables' do
      expect(build({ external_id: 42 })['id']).to eq('gid://shopify/ProductVariant/42')
    end

    it 'leaves out a template with a missing variable instead of sending it half-built' do
      expect(build({ available_quantity: 3 })).to eq('quantity' => 3)
    end

    it 'leaves out a settings value the account does not have' do
      expect(build({ available_quantity: 3 })).not_to have_key('locationId')
    end
  end
end
