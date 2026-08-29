# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Shipments::ProcessTrackingUpdate, type: :poro do
  subject(:process) { described_class.new(webhook_log: log) }

  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:integration) { CompanyIntegration.create!(company: company, service: create_service) }
  let(:shipment) do
    # La orden se crea acá adentro y no como let propio: ningún ejemplo la
    # necesita por separado, sólo existe porque un envío pertenece a una venta.
    order = Order.create!(company: company, customer_name: 'Juan Perez', status: 'paid')
    Shipment.create!(company: company, company_integration: integration, order: order,
                     tracking_number: 'AND-001', status: 'ready_to_ship')
  end
  let(:payload) { tracking_payload }
  let(:log) { create_log }

  before do
    Current.company_id = company.id
    shipment
  end

  # Plantilla del courier: dónde vive cada dato del tracking dentro del payload
  # crudo y cómo se traduce el estado externo al vocabulario interno.
  def tracking_mapper
    { 'numeroDeEnvio' => 'tracking_number', 'estado' => 'external_status',
      'fecha' => 'occurred_at', 'detalle' => 'description' }
  end

  def create_service(mapper: tracking_mapper,
                     value_mapper: { 'Entregado' => 'delivered', 'En camino' => 'in_transit' })
    Service.create!(service_name: "Andreani #{SecureRandom.hex(4)}", type: 'courier',
                    http_method: 'POST', uri: 'https://api.andreani.com/tracking',
                    response_mapper: mapper, response_value_mapper: value_mapper)
  end

  def tracking_payload(tracking_number: 'AND-001', estado: 'Entregado',
                       fecha: '2026-08-20T12:00:00Z', detalle: 'Entregado al destinatario')
    { 'numeroDeEnvio' => tracking_number, 'estado' => estado, 'fecha' => fecha,
      'detalle' => detalle }.compact
  end

  def create_log(body = payload, integ = integration)
    WebhookLog.create!(company_id: company.id, company_integration: integ, payload: body)
  end

  context 'when the courier reports a status the template can translate' do
    it 'creates the shipment event with the translated and the raw status', :aggregate_failures do
      event = process.call

      expect(event).to have_attributes(shipment: shipment, external_status: 'Entregado',
                                       internal_status: 'delivered',
                                       description: 'Entregado al destinatario')
      expect(event.occurred_at).to be_within(1.second).of(Time.zone.parse('2026-08-20T12:00:00Z'))
    end

    it 'advances the shipment to the translated status' do
      expect { process.call }.to change { shipment.reload.status }
        .from('ready_to_ship').to('delivered')
    end

    it 'marks the webhook log as processed' do
      expect { process.call }.to change { log.reload.status }.from('pending').to('processed')
    end
  end

  context 'when the courier reports a status the template does not map' do
    let(:payload) { tracking_payload(estado: 'Retenido en aduana') }

    before { shipment.update!(status: 'in_transit') }

    it 'registers the event as informative without moving the shipment status',
       :aggregate_failures do
      event = process.call

      expect(event).to have_attributes(external_status: 'Retenido en aduana',
                                       internal_status: 'in_transit')
      expect(shipment.reload.status).to eq('in_transit')
    end

    it 'marks the webhook log as processed anyway' do
      expect { process.call }.to change { log.reload.status }.to('processed')
    end
  end

  context 'when the exact same event arrives twice' do
    before { described_class.new(webhook_log: create_log).call }

    it 'does not create a second event' do
      expect { process.call }.not_to change(ShipmentEvent, :count)
    end

    it 'does not fail and leaves the duplicate log processed', :aggregate_failures do
      expect { process.call }.not_to raise_error
      expect(log.reload.status).to eq('processed')
    end
  end

  context 'when an older event arrives after a newer one was already registered' do
    let(:payload) { tracking_payload(estado: 'En camino', fecha: '2026-08-20T09:00:00Z') }

    before { described_class.new(webhook_log: create_log(tracking_payload)).call }

    it 'does not register the stale event nor move the shipment status backwards',
       :aggregate_failures do
      expect { process.call }.not_to change(ShipmentEvent, :count)
      expect(shipment.reload.status).to eq('delivered')
    end

    it 'marks the webhook log as processed' do
      expect { process.call }.to change { log.reload.status }.to('processed')
    end
  end

  context 'when the tracking number does not belong to any shipment' do
    let(:payload) { tracking_payload(tracking_number: 'UNKNOWN-999') }

    it 'processes nothing and does not raise', :aggregate_failures do
      result = nil
      expect { result = process.call }.not_to change(ShipmentEvent, :count)
      expect(result).to be_nil
    end

    it 'leaves the webhook log processed so the courier stops retrying' do
      expect { process.call }.to change { log.reload.status }.from('pending').to('processed')
    end
  end

  context 'when the payload does not carry a tracking number' do
    let(:payload) { tracking_payload.except('numeroDeEnvio') }

    it 'raises InvalidPayloadError' do
      expect { process.call }
        .to raise_error(described_class::InvalidPayloadError, /tracking number/)
    end

    it 'leaves the webhook log failed with the reason', :aggregate_failures do
      suppress(described_class::InvalidPayloadError) { process.call }

      expect(log.reload.status).to eq('failed')
      expect(log.error_message).to include('InvalidPayloadError')
    end
  end

  context 'when the payload does not carry an external status' do
    let(:payload) { tracking_payload.except('estado') }

    it 'raises InvalidPayloadError' do
      expect { process.call }
        .to raise_error(described_class::InvalidPayloadError, /external status/)
    end
  end

  context 'when the courier does not send an occurrence timestamp' do
    let(:payload) { tracking_payload.except('fecha') }

    it 'falls back to the moment the event was processed' do
      event = process.call
      expect(event.occurred_at).to be_within(5.seconds).of(Time.current)
    end
  end

  context 'when the same undated event is delivered twice as separate webhook logs' do
    let(:payload) { tracking_payload.except('fecha') }

    before { described_class.new(webhook_log: create_log).call }

    it 'does not create a second event, even though occurred_at differs per delivery' do
      expect { process.call }.not_to change(ShipmentEvent, :count)
    end

    it 'leaves the retried log processed' do
      expect { process.call }.to change { log.reload.status }.to('processed')
    end
  end

  context 'when an undated event reports a status different from the last known one' do
    let(:payload) { tracking_payload(estado: 'En camino').except('fecha') }

    before { described_class.new(webhook_log: create_log(tracking_payload(estado: 'Entregado'))).call }

    it 'still registers it, since it is not a retry of the last event' do
      expect { process.call }.to change(ShipmentEvent, :count).by(1)
    end
  end

  context 'when the webhook log was already processed' do
    before { log.update!(status: :processed) }

    it 'does nothing', :aggregate_failures do
      result = :not_nil
      expect { result = process.call }.not_to change(ShipmentEvent, :count)
      expect(result).to be_nil
    end
  end
end
