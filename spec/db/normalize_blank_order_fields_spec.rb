# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20261016145314_normalize_blank_order_fields')

# La corrección de datos de TESIS-178/179: las órdenes guardadas antes del
# `normalizes` con `''` pasan a NULL, y las que tienen un dato no se tocan.
RSpec.describe NormalizeBlankOrderFields do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }

  # SQL directo: `update_columns` también pasa por `normalizes`, y lo que hace
  # falta es una fila como las que quedaron guardadas antes de TESIS-178.
  def stored_before_the_normalization
    order = Order.create!(company: company, customer_name: 'Ana', customer_city: 'La Plata')
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      UPDATE orders SET customer_province = '', customer_email = '  ', customer_zip_code = '1900'
      WHERE id = #{order.id}
    SQL
    order
  end

  it 'starts from a row with blanks stored' do
    order = stored_before_the_normalization
    expect(Order.where(id: order.id).pick(Arel.sql("customer_province = ''"))).to be(true)
  end

  it 'turns a stored blank into NULL and leaves real values alone' do
    order = stored_before_the_normalization
    ActiveRecord::Migration.suppress_messages { described_class.new.up }

    expect(order.reload).to have_attributes(customer_province: nil, customer_email: nil,
                                            customer_zip_code: '1900', customer_city: 'La Plata')
  end
end
