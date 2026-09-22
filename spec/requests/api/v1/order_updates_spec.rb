# frozen_string_literal: true

require 'rails_helper'

# PUT /api/v1/orders/:id (TESIS-126). Las reglas del reemplazo de líneas y de
# los movimientos de stock se prueban en los specs de Orders::UpdateOrder y
# Orders::ReplaceOrderLines; acá, el contrato HTTP: qué status responde cada
# caso, qué devuelve y cómo viaja la versión.
RSpec.describe 'Order updates API', type: :request do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:user) { User.create!(email: 'a@acme.com', password: 'pass123', company: company) }
  let(:headers) { auth_headers(user) }

  def auth_headers(user)
    post '/api/v1/auth/login', params: { email: user.email, password: 'pass123' },
                               headers: { 'X-Tenant-Slug' => user.company.slug }
    { 'Authorization' => "Bearer #{response.parsed_body['token']}" }
  end

  def product = @product ||= Product.create!(company: company, sku: 'CEL-1', name: 'Celular')

  def warehouse
    @warehouse ||= Warehouse.create!(company: company, name: 'Central', zip_code: '1900',
                                     address: 'Av 1')
  end

  # Una línea de 4 a $100 que salió de Central, que queda con 20 unidades.
  def order
    @order ||= begin
      Stock.create!(product: product, warehouse: warehouse, quantity: 24)
      Orders::CreateOrder.new(
        params: { customer_name: 'Juan Pérez' },
        items: [{ product_id: product.id, warehouse_id: warehouse.id, quantity: 4, unit_price: 100 }],
        company: company
      ).call
    end
  end

  def line = order.order_items.first

  def stock_left = Stock.find_by(product: product, warehouse: warehouse).quantity

  # El body viaja como keywords (`put_order(customer_name: 'Otro')`); ninguna
  # columna de la orden se llama `if_match` ni `target`.
  def put_order(if_match: nil, target: order, **body)
    extra = if_match ? { 'If-Match' => %("#{if_match}") } : {}
    put "/api/v1/orders/#{target.id}", params: { order: body }, headers: headers.merge(extra),
                                       as: :json
  end

  def current_version = Orders::OrderVersion.new(order: Order.find(order.id)).call

  it 'returns 401 without a token' do
    put "/api/v1/orders/#{order.id}", params: { order: { customer_name: 'Otro' } }, as: :json

    expect(response).to have_http_status(:unauthorized)
  end

  describe 'a successful update' do
    it 'returns 200 with the order as the detail returns it', :aggregate_failures do
      put_order(customer_address: 'Av. Rivadavia 1234', status: 'paid')

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include('customer_address' => 'Av. Rivadavia 1234',
                                              'status' => 'paid')
    end

    it 'returns the lines with their product and warehouse' do
      put_order(customer_name: 'Otro')

      expect(response.parsed_body['order_items'].sole)
        .to include('warehouse_id' => warehouse.id, 'product' => include('sku' => 'CEL-1'))
    end

    # El cliente puede volver a guardar con esta versión sin pedir el detalle.
    it 'returns the new version as the ETag' do
      put_order(customer_name: 'Otro')

      expect(response.headers['ETag']).to eq(%("#{current_version}"))
    end
  end

  describe 'the lines' do
    it 'replaces them and moves the stock against the warehouse of each line', :aggregate_failures do
      put_order(items: [{ id: line.id, quantity: 6 }])

      expect(stock_left).to eq(18)
      expect(response.parsed_body['total_amount']).to eq(600.0)
    end

    it 'gives the stock back of a line that is not sent' do
      put_order(items: [{ product_id: product.id, warehouse_id: warehouse.id, quantity: 1,
                          unit_price: 100 }])

      expect(stock_left).to eq(23)
    end

    it 'leaves them alone when the body does not carry them', :aggregate_failures do
      put_order(customer_name: 'Otro')

      expect(line.reload.quantity).to eq(4)
      expect(stock_left).to eq(20)
    end
  end

  describe 'the version' do
    it 'accepts the ETag the detail returned' do
      get "/api/v1/orders/#{order.id}", headers: headers
      put_order(customer_name: 'Otro', if_match: response.headers['ETag'].delete('"'))

      expect(response).to have_http_status(:ok)
    end

    # Otro operador cambió una cantidad entre que la pantalla leyó y guardó.
    context 'when the order changed since it was read' do
      let!(:seen) { current_version }

      before { line.update!(quantity: 5) }

      it 'returns 412 with the current version', :aggregate_failures do
        put_order(customer_name: 'Otro', if_match: seen)

        expect(response).to have_http_status(:precondition_failed)
        expect(response.parsed_body['current_version']).to eq(current_version)
      end

      it 'does not write anything' do
        put_order(customer_name: 'Otro', if_match: seen)

        expect(order.reload.customer_name).to eq('Juan Pérez')
      end
    end
  end

  describe 'orders that cannot be modified' do
    it 'returns 409 for a cancelled order', :aggregate_failures do
      order.update!(status: 'cancelled')
      put_order(customer_name: 'Otro')

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body['error']).to eq('a cancelled order cannot be modified')
    end

    it 'returns 409 for an order whose shipment already left' do
      Shipment.create!(company: company, order: order, status: 'in_transit')
      put_order(customer_name: 'Otro')

      expect(response).to have_http_status(:conflict)
    end
  end

  describe 'tenant isolation' do
    def foreign_order
      @foreign_order ||= Current.set(company_id: nil) do
        other = Company.create!(name: 'Rival', tax_id: '30-88888888-1')
        Order.create!(company: other, customer_name: 'Ajeno')
      end
    end

    # 404 y no 403: un 403 confirmaría que esa orden existe.
    it 'returns 404 for an order of another company', :aggregate_failures do
      put_order(customer_name: 'Intruso', target: foreign_order)

      expect(response).to have_http_status(:not_found)
      expect(foreign_order.reload.customer_name).to eq('Ajeno')
    end
  end

  describe 'rejected requests' do
    it 'returns 422 when the warehouse cannot cover a line that grows', :aggregate_failures do
      put_order(items: [{ id: line.id, quantity: 99 }])

      expect(response).to have_http_status(:unprocessable_content)
      expect(stock_left).to eq(20)
    end

    it 'returns 422 when asked to cancel the order' do
      put_order(status: 'cancelled')

      expect(response.parsed_body['error']).to eq('status can only change to pending or paid')
    end

    it 'returns 422 for a line that does not record its warehouse' do
      blind = OrderItem.create!(order: order, product: product, quantity: 1, unit_price: 100)
      put_order(items: [{ id: line.id, quantity: 4 }])

      expect(response.parsed_body['error']).to start_with("line #{blind.id} does not record")
    end

    # Con un JSON que trae campos, ParamsWrapper los envuelve solo bajo `order`;
    # el 400 queda para el body vacío, igual que en el alta.
    it 'returns 400 without the order in the body' do
      put "/api/v1/orders/#{order.id}", params: {}, headers: headers, as: :json

      expect(response).to have_http_status(:bad_request)
    end
  end
end
