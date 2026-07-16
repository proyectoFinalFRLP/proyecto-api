require 'rails_helper'

RSpec.describe Service, type: :model do
  subject(:service) do
    described_class.new(service_name: 'Mercado Libre', type: 'ecommerce',
                        uri: 'https://api.ml.com', http_method: 'GET')
  end

  it 'is valid with the required attributes' do
    expect(service).to be_valid
  end

  %i[service_name type uri http_method].each do |attribute|
    it "is invalid without #{attribute}" do
      service.public_send("#{attribute}=", nil)
      expect(service).not_to be_valid
    end
  end

  it 'is invalid with an unknown type' do
    service.type = 'marketplace'
    expect(service).not_to be_valid
  end

  it 'enforces service_name uniqueness' do
    service.save!
    duplicate = described_class.new(service_name: service.service_name, type: 'courier',
                                    uri: 'https://x.com', http_method: 'POST')
    expect(duplicate).not_to be_valid
  end

  it 'does not treat `type` as STI' do
    expect(described_class.new(type: 'ecommerce')).to be_an_instance_of(described_class)
  end

  it 'persists nested JSONB mappers', :aggregate_failures do
    service.update!(request_mapper: { 'order' => { 'id' => 'external_id' } })
    expect(service.reload.request_mapper).to eq('order' => { 'id' => 'external_id' })
  end

  it 'has many company_integrations' do
    expect(described_class.reflect_on_association(:company_integrations).macro).to eq(:has_many)
  end

  describe 'mapper coercion from String (formularios del backoffice)' do
    it 'parses a valid JSON string into a Hash' do
      service.request_mapper = '{"a": "b"}'
      expect(service.request_mapper).to eq('a' => 'b')
    end

    it 'accepts a Hash untouched' do
      service.request_mapper = { 'a' => 'b' }
      expect(service.request_mapper).to eq('a' => 'b')
    end

    it 'coerces a blank string into an empty Hash' do
      service.request_mapper = '   '
      expect(service.request_mapper).to eq({})
    end

    it 'marks the record invalid on malformed JSON', :aggregate_failures do
      service.request_mapper = '{esto no es json'
      expect(service).not_to be_valid
      expect(service.errors[:request_mapper]).to include('no es un JSON válido')
    end

    it 'marks the record invalid when the JSON is not an object' do
      service.request_mapper = '"solo-un-string"'
      expect(service).not_to be_valid
    end

    it 'keeps the previous value when the new JSON is malformed' do
      service.update!(request_mapper: { 'a' => 'b' })
      service.request_mapper = '{roto'
      expect(service.request_mapper).to eq('a' => 'b')
    end

    it 'becomes valid again when the mapper is reassigned with valid JSON', :aggregate_failures do
      service.request_mapper = '{roto'
      service.request_mapper = '{"a": "b"}'
      expect(service).to be_valid
      expect(service.request_mapper).to eq('a' => 'b')
    end
  end
end
