# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Shipments::PollTrackingStatus, type: :poro do
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:tracking_template) { single_template }
  let(:integration) do
    courier_integration(company: company,
                        service: courier_service('Correo', tracking_service: tracking_template),
                        credentials: { 'access_token' => 'SECRET-TOKEN' })
  end
  let!(:shipment) { create_shipment('CA-001') }

  before { Current.company_id = company.id }

  # Una consulta por envío: el número va en la URI.
  def single_template
    courier_service('Correo - Seguimiento',
                    http_method: 'GET', uri: 'https://correo.test/tracking/:tracking_number',
                    response_mapper: { 'ultimo.estado' => 'external_status',
                                       'ultimo.fecha' => 'occurred_at',
                                       'ultimo.planta' => 'description' },
                    response_value_mapper: { 'EN TRANSITO' => 'in_transit',
                                             'ENTREGADO' => 'delivered' })
  end

  # Consulta masiva: los números van juntos y la respuesta lista un envío por
  # elemento.
  def batch_template
    courier_service('Correo - Seguimiento masivo',
                    http_method: 'GET', uri: 'https://correo.test/tracking?envios=:tracking_numbers',
                    response_mapper: { 'envios[].numero' => 'tracking_number',
                                       'envios[].estado' => 'external_status',
                                       'envios[].fecha' => 'occurred_at' },
                    response_value_mapper: { 'EN TRANSITO' => 'in_transit',
                                             'ENTREGADO' => 'delivered' })
  end

  def create_shipment(tracking, status: 'ready_to_ship')
    order = Order.create!(company: company, customer_name: 'Juan Perez', status: 'paid')
    Shipment.create!(company: company, company_integration: integration, order: order,
                     tracking_number: tracking, status: status)
  end

  def reply(tracking, estado: 'EN TRANSITO', fecha: '2026-09-20T10:00:00Z', status: 200)
    stub_request(:get, "https://correo.test/tracking/#{tracking}")
      .to_return(status: status, body: { ultimo: { estado: estado, fecha: fecha,
                                                   planta: 'CTP Monte Grande' } }.to_json)
  end

  def batch_url = 'https://correo.test/tracking?envios=CA-001,CA-002'

  def poll(ids = [shipment.id])
    described_class.new(company_integration: integration, shipment_ids: ids).call
  end

  context 'with a template that answers one shipment per request' do
    before { reply('CA-001') }

    it 'asks the courier with its tracking template and the integration credentials' do
      poll
      expect(WebMock).to have_requested(:get, 'https://correo.test/tracking/CA-001')
        .with(headers: { 'Authorization' => 'Bearer SECRET-TOKEN' })
    end

    it 'registers the movement with the raw and the translated status', :aggregate_failures do
      event = poll.sole

      expect(event).to have_attributes(external_status: 'EN TRANSITO', internal_status: 'in_transit',
                                       description: 'CTP Monte Grande')
      expect(shipment.reload.status).to eq('in_transit')
    end

    it 'does not register the same movement twice across cycles' do
      poll
      expect { poll }.not_to change(ShipmentEvent, :count)
    end

    it 'registers a new movement within the same status' do
      poll
      reply('CA-001', fecha: '2026-09-20T18:00:00Z')

      expect { poll }.to change(ShipmentEvent, :count).by(1)
    end
  end

  context 'when the courier fails for one shipment' do
    let!(:other) { create_shipment('CA-002') }

    before do
      reply('CA-001', status: 503)
      reply('CA-002', estado: 'ENTREGADO')
    end

    it 'still polls and updates the rest', :aggregate_failures do
      expect { poll([shipment.id, other.id]) }.not_to raise_error
      expect(other.reload.status).to eq('delivered')
      expect(shipment.reload.status).to eq('ready_to_ship')
    end

    it 'logs the failure' do
      allow(Rails.logger).to receive(:warn)
      poll([shipment.id, other.id])
      expect(Rails.logger).to have_received(:warn).with(/tracking query failed.*HTTP 503/)
    end
  end

  context 'when the courier times out' do
    before { stub_request(:get, 'https://correo.test/tracking/CA-001').to_timeout }

    it 'returns nothing instead of raising' do
      expect(poll).to be_empty
    end
  end

  context 'when the response does not locate an external status' do
    before do
      stub_request(:get, 'https://correo.test/tracking/CA-001')
        .to_return(status: 200, body: { otra: 'cosa' }.to_json)
    end

    it 'registers nothing' do
      expect { poll }.not_to change(ShipmentEvent, :count)
    end
  end

  context 'when a movement cannot be saved' do
    let!(:other) { create_shipment('CA-002') }

    before do
      reply('CA-001')
      reply('CA-002')
      allow(Shipments::RegisterTrackingEvent).to receive(:new).and_call_original
      allow(Shipments::RegisterTrackingEvent).to receive(:new)
        .with(shipment: shipment, translated: anything).and_raise(ActiveRecord::StatementInvalid)
    end

    it 'keeps registering the other shipments' do
      expect(poll([shipment.id, other.id]).map(&:shipment)).to eq([other])
    end
  end

  context 'when the shipment is no longer in flight' do
    before { shipment.update!(status: 'delivered') }

    it 'does not ask the courier about it' do
      poll
      expect(WebMock).not_to have_requested(:get, /correo\.test/)
    end
  end

  context 'when the id belongs to another tenant' do
    let(:foreign) do
      other_company = Company.create!(name: 'Otra', tax_id: '20-99999999-9')
      Current.company_id = other_company.id
      other_integration = courier_integration(company: other_company, service: integration.service)
      order = Order.create!(company: other_company, customer_name: 'Ana', status: 'paid')
      Shipment.create!(company: other_company, company_integration: other_integration,
                       order: order, tracking_number: 'CA-999', status: 'in_transit')
    ensure
      Current.company_id = company.id
    end

    it 'ignores it' do
      poll([foreign.id])
      expect(WebMock).not_to have_requested(:get, /correo\.test/)
    end
  end

  context 'when the courier has no tracking template' do
    let(:tracking_template) { nil }

    it 'does nothing' do
      expect(poll).to be_empty
    end
  end

  context 'with a template that answers many shipments per request' do
    let(:tracking_template) { batch_template }
    let!(:other) { create_shipment('CA-002', status: 'in_transit') }

    before do
      stub_request(:get, batch_url).to_return(status: 200, body: {
        envios: [
          { numero: 'CA-002', estado: 'ENTREGADO', fecha: '2026-09-20T12:00:00Z' },
          { numero: 'CA-001', estado: 'EN TRANSITO', fecha: '2026-09-20T11:00:00Z' },
          { numero: 'AJENO-1', estado: 'ENTREGADO', fecha: '2026-09-20T11:00:00Z' }
        ]
      }.to_json)
    end

    it 'asks for every shipment in a single request' do
      poll([shipment.id, other.id])
      expect(WebMock).to have_requested(:get, batch_url).once
    end

    it 'pairs each element with its shipment by tracking number', :aggregate_failures do
      poll([shipment.id, other.id])

      expect(shipment.reload.status).to eq('in_transit')
      expect(other.reload.status).to eq('delivered')
    end

    it 'ignores the elements that are not about these shipments' do
      expect(poll([shipment.id, other.id]).size).to eq(2)
    end

    # La consulta masiva pregunta por varios envíos de una vez, así que cuando
    # se cae se cae para todos. El camino de un envío por request ya estaba
    # probado contra el timeout; este no, y es el que decide si el barrido
    # sigue o se levanta una excepción con la ronda entera adentro (TESIS-93).
    context 'when the batch query fails' do
      before { stub_request(:get, batch_url).to_timeout }

      it 'returns nothing instead of raising' do
        expect(poll([shipment.id, other.id])).to be_empty
      end

      it 'registers no movement' do
        expect { poll([shipment.id, other.id]) }.not_to change(ShipmentEvent, :count)
      end

      it 'leaves the shipments as they were' do
        poll([shipment.id, other.id])

        expect(shipment.reload.status).to eq('ready_to_ship')
      end
    end

    # Los números los mandamos nosotros: un elemento que no es de ninguno es la
    # pista de una plantilla mal configurada, y tiene que quedar en el log.
    it 'logs the element that matches no shipment of the query' do
      allow(Rails.logger).to receive(:warn)
      poll([shipment.id, other.id])

      expect(Rails.logger).to have_received(:warn).with(/AJENO-1 matches no shipment/)
    end
  end

  context 'when a batch element does not carry its tracking number' do
    let(:tracking_template) { batch_template }

    before do
      stub_request(:get, 'https://correo.test/tracking?envios=CA-001').to_return(status: 200, body: {
        envios: [{ estado: 'ENTREGADO', fecha: '2026-09-20T12:00:00Z' }]
      }.to_json)
    end

    it 'logs it instead of dropping it silently' do
      allow(Rails.logger).to receive(:warn)
      poll

      expect(Rails.logger).to have_received(:warn).with(/no tracking number matches no shipment/)
    end
  end

  context 'when a single-shipment response talks about another tracking number' do
    let(:tracking_template) do
      single_template.tap do |template|
        template.update!(response_mapper: template.response_mapper
                                                  .merge('numero' => 'tracking_number'))
      end
    end

    before do
      stub_request(:get, 'https://correo.test/tracking/CA-001')
        .to_return(status: 200, body: { numero: 'CA-777', ultimo: { estado: 'ENTREGADO' } }.to_json)
    end

    it 'does not write it into this shipment' do
      expect { poll }.not_to change(ShipmentEvent, :count)
    end
  end
end
