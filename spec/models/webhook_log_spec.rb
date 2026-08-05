# frozen_string_literal: true

require 'rails_helper'

RSpec.describe WebhookLog, type: :model do
  subject(:webhook_log) do
    described_class.new(company: company, company_integration: integration)
  end

  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:service) do
    Service.create!(service_name: 'Andreani', type: 'courier',
                    uri: 'https://api.andreani.com', http_method: 'POST')
  end
  let(:integration) { CompanyIntegration.create!(company: company, service: service) }

  after { Current.reset }

  it 'is valid with a company and an integration' do
    expect(webhook_log).to be_valid
  end

  it 'defaults to pending status with empty jsonb columns', :aggregate_failures do
    webhook_log.save!
    expect(webhook_log.status).to eq('pending')
    expect(webhook_log.payload).to eq({})
    expect(webhook_log.headers).to eq({})
  end

  it 'is invalid with an unknown status' do
    webhook_log.status = 'exploded'
    expect(webhook_log).not_to be_valid
  end

  it 'is invalid when the integration belongs to another company' do
    webhook_log.company = Company.create!(name: 'Otra', tax_id: '30-99999999-9')
    expect(webhook_log).not_to be_valid
  end

  # Sin esta validación, un Current heredado haría que assign_current_company
  # pisara el company_id explícito y el log terminara en el tenant equivocado
  # en silencio. Acá falla fuerte en vez de escribir mal.
  it 'refuses to write under a leaked tenant instead of doing it silently' do
    integration
    Current.company_id = Company.create!(name: 'Intruso', tax_id: '30-88888888-8').id

    log = described_class.new(company_id: company.id, company_integration: integration)

    expect(log).not_to be_valid
  end

  it 'rejects an unknown status at the database level' do
    webhook_log.save!
    sql = "UPDATE webhook_logs SET status = 'nope' WHERE id = #{webhook_log.id}"
    expect { described_class.connection.execute(sql) }
      .to raise_error(ActiveRecord::StatementInvalid, /webhook_logs_status_check/)
  end

  it 'persists nested payloads as native JSON' do
    webhook_log.update!(payload: { 'order' => { 'items' => [{ 'sku' => 'A1' }] } })
    expect(webhook_log.reload.payload).to eq('order' => { 'items' => [{ 'sku' => 'A1' }] })
  end

  it 'scopes queries to the current tenant' do
    webhook_log.save!
    Current.company_id = Company.create!(name: 'Otra', tax_id: '30-99999999-9').id
    expect(described_class.all).to be_empty
  end

  it 'exposes a pending scope' do
    webhook_log.save!
    expect(described_class.unscoped.pending).to contain_exactly(webhook_log)
  end
end
