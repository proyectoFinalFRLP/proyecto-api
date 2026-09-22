# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Orders::OrderVersion, type: :poro do
  def company = @company ||= Company.create!(name: 'Acme', tax_id: '20-12345678-9')
  def product = @product ||= Product.create!(company: company, sku: 'CEL-1', name: 'Celular')
  def order = @order ||= Order.create!(company: company, customer_name: 'Juan Pérez')

  def add_line(quantity: 2)
    OrderItem.create!(order: order, product: product, quantity: quantity, unit_price: 100)
  end

  def version = described_class.new(order: Order.includes(:order_items).find(order.id)).call

  before do
    Current.company_id = company.id
    add_line
  end

  it 'is the same for the same order read twice' do
    first_read = version
    expect(version).to eq(first_read)
  end

  it 'changes when a field of the customer changes' do
    expect { order.update!(customer_address: 'Av. 1') }.to(change { version })
  end

  it 'changes when the status changes' do
    expect { order.update!(status: 'paid') }.to(change { version })
  end

  # El caso para el que existe: dos operadores cambiando cantidades de la misma
  # orden no tocan la fila `orders`.
  it 'changes when the quantity of a line changes' do
    expect { order.order_items.first.update!(quantity: 5) }.to(change { version })
  end

  it 'changes when a line is added' do
    expect { add_line(quantity: 1) }.to(change { version })
  end

  it 'does not depend on the order in which the lines are loaded' do
    add_line(quantity: 1)
    reversed = Order.find(order.id).tap { |o| o.association(:order_items).target = o.order_items.to_a.reverse }

    expect(described_class.new(order: reversed).call).to eq(version)
  end
end
