# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Products::UpdateProduct, type: :poro do
  def company = @company ||= Company.create!(name: 'Acme', tax_id: '20-12345678-9')
  def product = @product ||= Product.create!(company: company, sku: 'CEL-1', name: 'Celular')

  def warehouse
    @warehouse ||= Warehouse.create!(company: company, name: 'Central', zip_code: '1900',
                                     address: 'Av 1')
  end

  before do
    Current.company_id = company.id
    Stock.create!(product: product, warehouse: warehouse, quantity: 10)
  end

  def current_version = Catalog::ProductVersion.new(product: product.reload).call

  def update(stocks:, expected_version: current_version)
    described_class.new(product: product, params: { name: 'Celular X' }, stocks: stocks,
                        expected_version: expected_version).call
  end

  # Desde otra sesión de Postgres, como lo vería una venta: el advisory lock es
  # reentrante dentro de la misma conexión, así que preguntarlo desde la del
  # test diría que está libre aunque no lo esté.
  def stock_lock_free_for_others?
    key = Catalog::WithStockLock.new(product_id: product.id).lock_key
    config = ActiveRecord::Base.connection_db_config.configuration_hash
    other = PG.connect(host: config[:host], port: config[:port], dbname: config[:database],
                       user: config[:username], password: config[:password])
    other.exec('BEGIN')
    other.exec("SELECT pg_try_advisory_xact_lock(#{key})").getvalue(0, 0) == 't'
  ensure
    other&.exec('ROLLBACK')
    other&.close
  end

  # Qué tan libre estaba el lock de stock en el momento en que se calculó la
  # versión del producto para compararla con el If-Match.
  def lock_free_while_checking_the_version
    observed = nil
    allow(Catalog::ProductVersion).to receive(:new).and_wrap_original do |original, **kwargs|
      observed = stock_lock_free_for_others?
      original.call(**kwargs)
    end
    yield
    observed
  end

  # Hallazgo de auditoría (TESIS-89). Si el lock se tomaba recién para escribir,
  # una venta entraba entre el chequeo y la escritura, la versión ya validada no
  # la veía y la cantidad absoluta del request la borraba sin rastro.
  it 'holds the stock lock while it checks the version, so no sale slips in between' do
    version = current_version

    free = lock_free_while_checking_the_version do
      update(stocks: [{ warehouse_id: warehouse.id, quantity: 3 }], expected_version: version)
    end

    expect(free).to be(false)
  end

  it 'takes no stock lock for a change that does not touch stocks' do
    version = current_version

    free = lock_free_while_checking_the_version { update(stocks: [], expected_version: version) }

    expect(free).to be(true)
  end

  it 'writes the stock it was sent' do
    update(stocks: [{ warehouse_id: warehouse.id, quantity: 3 }])

    expect(Stock.find_by(product: product, warehouse: warehouse).quantity).to eq(3)
  end

  it 'refuses a stale version and writes nothing', :aggregate_failures do
    expect { update(stocks: [{ warehouse_id: warehouse.id, quantity: 3 }], expected_version: 'stale') }
      .to raise_error(Catalog::StaleProductError)
    expect(Stock.find_by(product: product, warehouse: warehouse).quantity).to eq(10)
  end
end
