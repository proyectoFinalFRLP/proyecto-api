# frozen_string_literal: true

require 'rails_helper'

# Los filtros del panel de administración (TESIS-93).
#
# Son tres clases de tres líneas y ninguna tenía un ejemplo: si un filtro
# ignorara el valor elegido, el panel mostraría la tabla entera y el
# administrador no tendría cómo notarlo —una lista más larga de lo que pidió no
# parece un error—.
#
# Se prueban por `apply`, que es el único método que Avo les llama, con la
# consulta sin scopear: el aislamiento por empresa es de la API, y el backoffice
# ve a propósito todas las empresas.
RSpec.describe 'Avo filters', type: :model do
  let(:company) { Company.create!(name: 'Norte', tax_id: '30-11111111-1') }
  let(:other_company) { Company.create!(name: 'Sur', tax_id: '30-22222222-2') }
  let(:couriers) { {} }

  def order_for(a_company, status: 'pending')
    Current.set(company_id: a_company.id) do
      Order.create!(company: a_company, customer_name: 'Juan', status: status)
    end
  end

  # Una sola integración por empresa: un envío por orden, y dos integraciones de
  # la misma empresa pedirían dos couriers distintos.
  def courier_of(a_company)
    couriers[a_company.id] ||= Current.set(company_id: a_company.id) do
      courier_integration(company: a_company, name: "Andreani #{a_company.id}")
    end
  end

  def shipment_for(a_company, status: 'pending')
    courier = courier_of(a_company)

    Current.set(company_id: a_company.id) do
      order = Order.create!(company: a_company, customer_name: 'Juan', status: 'paid')
      Shipment.create!(company: a_company, order: order, company_integration: courier,
                       status: status)
    end
  end

  describe Avo::Filters::CompanyFilter do
    subject(:filter) { described_class.new }

    it 'keeps only the rows of the chosen company' do
      mine = order_for(company)
      order_for(other_company)

      expect(filter.apply(nil, Order.unscoped, company.id).pluck(:id)).to eq([mine.id])
    end

    it 'leaves the query untouched when nothing is chosen' do
      order_for(company)
      order_for(other_company)

      expect(filter.apply(nil, Order.unscoped, '').count).to eq(2)
    end

    it 'offers one option per company, by name', :aggregate_failures do
      company
      other_company

      expect(filter.options.values).to include('Norte', 'Sur')
    end
  end

  describe Avo::Filters::OrderStatusFilter do
    subject(:filter) { described_class.new }

    it 'keeps only the orders in the chosen status' do
      paid = order_for(company, status: 'paid')
      order_for(company, status: 'pending')

      expect(filter.apply(nil, Order.unscoped, 'paid').pluck(:id)).to eq([paid.id])
    end

    it 'leaves the query untouched when nothing is chosen' do
      order_for(company, status: 'paid')
      order_for(company, status: 'pending')

      expect(filter.apply(nil, Order.unscoped, nil).count).to eq(2)
    end

    it 'offers exactly the statuses an order can be in' do
      expect(filter.options.keys).to match_array(Order::STATUSES)
    end
  end

  describe Avo::Filters::ShipmentStatusFilter do
    subject(:filter) { described_class.new }

    it 'keeps only the shipments in the chosen status' do
      in_transit = shipment_for(company, status: 'in_transit')
      shipment_for(company, status: 'pending')

      expect(filter.apply(nil, Shipment.unscoped, 'in_transit').pluck(:id)).to eq([in_transit.id])
    end

    it 'leaves the query untouched when nothing is chosen' do
      shipment_for(company, status: 'in_transit')
      shipment_for(company, status: 'pending')

      expect(filter.apply(nil, Shipment.unscoped, '').count).to eq(2)
    end
  end
end
