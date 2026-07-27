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
end
