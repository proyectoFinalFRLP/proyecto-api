# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Orders::TranslateWebhookPayload, type: :poro do
  subject(:translated) { described_class.new(service: service, payload: payload).call }

  let(:mapper) do
    { 'id' => 'external_order_id', 'estado' => 'status',
      'comprador.nombre' => 'customer_name', 'envio.cp' => 'customer_zip_code',
      'lineas[].sku_externo' => 'external_product_id', 'lineas[].cantidad' => 'quantity',
      'lineas[].precio' => 'unit_price' }
  end
  let(:service) do
    Service.create!(service_name: 'Canal', type: 'ecommerce', http_method: 'GET',
                    uri: 'https://api.canal.test/orders', response_mapper: mapper,
                    response_value_mapper: { 'pagado' => 'paid' })
  end
  let(:payload) do
    { 'id' => 'ORD-1', 'estado' => 'pagado', 'comprador' => { 'nombre' => 'Ana' },
      'envio' => { 'cp' => '1900' },
      'lineas' => [{ 'sku_externo' => 'EXT-1', 'cantidad' => 2, 'precio' => '150.5' }] }
  end

  it 'translates the sale into internal keys' do
    expect(translated[:order]).to eq(external_order_id: 'ORD-1', status: 'paid',
                                     customer_name: 'Ana', customer_zip_code: '1900')
  end

  it 'translates every line of the sale' do
    expect(translated[:items]).to eq([{ external_product_id: 'EXT-1', quantity: 2,
                                        unit_price: '150.5' }])
  end

  # El response_mapper de una plantilla sirve a más de un flujo: el de un canal
  # puede mapear el tracking de la respuesta de un envío, que no es dato de venta.
  it 'ignores internal keys that are not part of a sale' do
    service.update!(response_mapper: mapper.merge('comprador.nombre' => 'tracking_number'))

    expect(translated[:order]).not_to have_key(:tracking_number)
  end

  it 'returns no items when the template does not describe the lines of the sale' do
    service.update!(response_mapper: { 'id' => 'external_order_id' })

    expect(translated[:items]).to eq([])
  end

  it 'returns only the keys the template actually maps' do
    service.update!(response_mapper: { 'id' => 'external_order_id' })

    expect(translated[:order]).to eq(external_order_id: 'ORD-1')
  end

  describe 'the count of unreadable items' do
    it 'is zero when every element of the list could be translated' do
      expect(translated[:unreadable_items]).to eq(0)
    end

    # El parser descarta el elemento intraducible porque es generico; contarlo
    # es lo que le deja a ProcessWebhookOrder decidir que hacer con la perdida.
    it 'counts the elements the template could not read' do
      payload['lineas'] << { 'otro_formato' => 'EXT-2' } << { 'otro_formato' => 'EXT-3' }

      expect(translated[:unreadable_items]).to eq(2)
    end

    it 'does not count them as items' do
      payload['lineas'] << { 'otro_formato' => 'EXT-2' }

      expect(translated[:items].size).to eq(1)
    end

    it 'is zero when the template describes no collection at all' do
      service.update!(response_mapper: { 'id' => 'external_order_id' })

      expect(translated[:unreadable_items]).to eq(0)
    end
  end
end
