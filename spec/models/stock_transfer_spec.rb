# frozen_string_literal: true

require 'rails_helper'

RSpec.describe StockTransfer, type: :model do
  subject(:transfer) do
    described_class.new(company: company, product: product, origin_warehouse: origin,
                        destination_warehouse: destination, quantity: 5,
                        dispatched_at: Time.current)
  end

  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:product) { Product.create!(company: company, sku: 'SKU-1', name: 'Widget') }
  let(:origin) { warehouse('Central', '1900') }
  let(:destination) { warehouse('North', '1901') }

  def warehouse(name, zip, owner: company)
    Warehouse.create!(company: owner, name: name, zip_code: zip, address: "Calle #{zip}")
  end

  def other_company
    @other_company ||= Company.create!(name: 'Other', tax_id: '30-22222222-2')
  end

  it 'is valid with the required attributes' do
    expect(transfer).to be_valid
  end

  it 'defaults to in_transit' do
    transfer.save!
    expect(transfer.status).to eq('in_transit')
  end

  it 'rejects a non-positive quantity' do
    transfer.quantity = 0
    expect(transfer).not_to be_valid
  end

  it 'rejects the same warehouse on both ends', :aggregate_failures do
    transfer.destination_warehouse = origin
    expect(transfer).not_to be_valid
    expect(transfer.errors[:destination_warehouse]).to be_present
  end

  # `validate: true` en el enum existe para que un estado desconocido invalide
  # el registro en lugar de explotar en el asignador (mismo criterio que
  # WebhookLog y FailedEvent).
  it 'rejects an unknown status without raising on assignment' do
    transfer.status = 'lost'
    expect(transfer).not_to be_valid
  end

  describe 'the same-company rule' do
    it 'rejects a product from another company' do
      transfer.product = Current.set(company_id: nil) do
        Product.create!(company: other_company, sku: 'B-1', name: 'Other')
      end
      expect(transfer).not_to be_valid
    end

    it 'rejects a warehouse from another company' do
      transfer.destination_warehouse = Current.set(company_id: nil) do
        warehouse('Foreign', '3000', owner: other_company)
      end
      expect(transfer).not_to be_valid
    end
  end

  describe 'the database constraints' do
    # Las validaciones del modelo son la primera línea; el CHECK es la que no se
    # puede saltear con update_all / SQL crudo. Mismo criterio que stocks.quantity.
    it 'rejects a non-positive quantity at the database level' do
      transfer.save!

      expect do
        described_class.where(id: transfer.id).update_all(quantity: 0) # rubocop:disable Rails/SkipsModelValidations
      end.to raise_error(ActiveRecord::StatementInvalid)
    end

    it 'rejects an unknown status at the database level' do
      transfer.save!

      expect do
        described_class.where(id: transfer.id).update_all(status: 'lost') # rubocop:disable Rails/SkipsModelValidations
      end.to raise_error(ActiveRecord::StatementInvalid)
    end
  end
end
