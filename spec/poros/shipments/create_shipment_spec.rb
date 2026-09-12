# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Shipments::CreateShipment, type: :poro do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:order) { order_with(status: 'pending') }

  before { Current.company_id = company.id }

  def order_with(status:, owner: company)
    Order.create!(company: owner, customer_name: 'Juan Pérez', customer_zip_code: '1900',
                  customer_address: 'Av. Siempreviva 742', status: status)
  end

  def create_shipment(target = order)
    described_class.new(order: target).call
  end

  # Corre el caso de uso tragándose el error de negocio: deja el camino
  # ejecutado para poder afirmar sobre lo que quedó (o no) en la base.
  def attempt_create(target = order)
    create_shipment(target)
  rescue Shipments::UnshippableOrderError, Shipments::DuplicateShipmentError
    nil
  end

  describe 'the shipment it creates' do
    subject(:shipment) { create_shipment }

    it 'belongs to the order' do
      expect(shipment.order_id).to eq(order.id)
    end

    it 'starts pending' do
      expect(shipment.status).to eq('pending')
    end

    # El envío nace sin operador: el courier, el número de seguimiento y el costo
    # los completa la confirmación del despacho (TESIS-47).
    it 'starts with no courier, no tracking and no cost', :aggregate_failures do
      expect(shipment.company_integration_id).to be_nil
      expect(shipment.tracking_number).to be_nil
      expect(shipment.shipping_cost).to be_nil
    end

    it 'inherits the company of the order' do
      expect(shipment.company_id).to eq(company.id)
    end

    it 'persists it' do
      expect { shipment }.to change(Shipment, :count).by(1)
    end
  end

  it 'creates a shipment for an order already marked as paid' do
    expect(create_shipment(order_with(status: 'paid')).status).to eq('pending')
  end

  describe 'when the order is cancelled' do
    let(:order) { order_with(status: 'cancelled') }

    it 'raises UnshippableOrderError' do
      expect { create_shipment }.to raise_error(Shipments::UnshippableOrderError,
                                                /'cancelled' cannot be shipped/)
    end

    it 'does not create anything' do
      expect { attempt_create }.not_to change(Shipment, :count)
    end
  end

  describe 'when the order already has a shipment' do
    before { create_shipment }

    it 'raises DuplicateShipmentError' do
      expect { create_shipment }.to raise_error(Shipments::DuplicateShipmentError)
    end

    it 'leaves the original shipment as the only one' do
      expect { attempt_create }.not_to change(Shipment, :count)
    end

    it 'carries the order id in the error' do
      expect { create_shipment }.to raise_error(
        having_attributes(class: Shipments::DuplicateShipmentError, order_id: order.id)
      )
    end

    # El caso normal lo ataja `validates :order_id, uniqueness: true` antes de
    # llegar a la base. La carrera real —dos transacciones que pasan la
    # validación antes de que cualquiera confirme— sólo la ataja el índice
    # único, y tiene que salir como el mismo error de negocio.
    it 'maps the unique index violation to the same error' do
      allow(Shipment).to receive(:create!).and_raise(ActiveRecord::RecordNotUnique)

      expect { create_shipment }.to raise_error(Shipments::DuplicateShipmentError)
    end
  end

  # Cualquier otro RecordInvalid no es un conflicto: un envío que no valida por
  # otro motivo tiene que seguir saliendo como 422 y no como 409.
  it 'lets an unrelated validation error through' do
    foreign_order = Current.set(company_id: nil) do
      other = Company.create!(name: 'Otra', tax_id: '30-99999999-9')
      order_with(status: 'pending', owner: other)
    end

    expect { create_shipment(foreign_order) }.to raise_error(ActiveRecord::RecordInvalid)
  end
end
