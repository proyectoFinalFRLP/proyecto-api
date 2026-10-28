# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Webhooks::ErrorCatalog do
  def adapter_error(message = 'Andreani failed', cause: nil, **options)
    raise Integrations::AdapterExecutionError.new(message, **options), cause: cause
  rescue Integrations::AdapterExecutionError => e
    e
  end

  describe '.code_for' do
    it 'answers nil when there is no error' do
      expect(described_class.code_for(nil)).to be_nil
    end

    it 'codes an error by its class' do
      error = Webhooks::Replayers::OrderIngestion::MissingWebhookLog.new('gone')

      expect(described_class.code_for(error)).to eq('ORD-003')
    end

    # Una subclase sin entrada propia hereda el código del padre en vez de caer
    # en el genérico.
    it 'codes a subclass with the code of its parent' do
      subclass = Class.new(Orders::ProcessWebhookOrder::UnmappedProductError)

      expect(described_class.code_for(subclass.new('x'))).to eq('ORD-002')
    end

    it 'codes the two missing value errors alike', :aggregate_failures do
      template = Integrations::RenderTemplate::MissingValueError.new('height')
      adapter = Integrations::MissingValueError.new('needs height', missing_value: 'height')

      expect(described_class.code_for(template)).to eq('INT-010')
      expect(described_class.code_for(adapter)).to eq('INT-010')
    end

    it 'codes an error nobody catalogued as unexpected' do
      expect(described_class.code_for(ArgumentError.new('x'))).to eq('GEN-000')
    end

    context 'with an adapter error' do
      {
        401 => 'INT-002', 403 => 'INT-002', 404 => 'INT-003', 429 => 'INT-004',
        500 => 'INT-005', 503 => 'INT-005', 400 => 'INT-008', 422 => 'INT-008'
      }.each do |status, code|
        it "codes an HTTP #{status} as #{code}" do
          expect(described_class.code_for(adapter_error(response_status: status))).to eq(code)
        end
      end

      {
        Net::OpenTimeout.new => 'INT-006', Net::ReadTimeout.new => 'INT-006',
        Errno::ECONNREFUSED.new => 'INT-007', SocketError.new => 'INT-007',
        JSON::ParserError.new('x') => 'INT-009',
        Integrations::ParseXmlResponse::MalformedXmlError.new('x') => 'INT-009',
        Integrations::RenderTemplate::UnknownFilterError.new('x') => 'INT-011'
      }.each do |cause, code|
        it "codes one caused by #{cause.class} as #{code}" do
          expect(described_class.code_for(adapter_error(cause: cause))).to eq(code)
        end
      end

      # El status es lo que el proveedor contestó: manda sobre la causa.
      it 'reads the status before the cause' do
        error = adapter_error(cause: Net::ReadTimeout.new, response_status: 503)

        expect(described_class.code_for(error)).to eq('INT-005')
      end

      it 'codes a rejection that came with HTTP 200 as a rejected request' do
        expect(described_class.code_for(adapter_error(rejected: true))).to eq('INT-008')
      end

      it 'codes one with nothing else to tell as a failed communication' do
        expect(described_class.code_for(adapter_error)).to eq('INT-001')
      end

      it 'codes a missing required value before reading it as a rejection' do
        error = Integrations::MissingValueError.new('needs height', missing_value: 'height')

        expect(described_class.code_for(error)).to eq('INT-010')
      end
    end

    # De punta a punta: la `cause` la completa Ruby cuando el HttpAdapter
    # levanta dentro de su rescue. Si alguien la pierde, el código cae a INT-001.
    context 'when the error comes out of the HttpAdapter' do
      let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
      let(:integration) do
        service = Service.create!(service_name: 'Andreani', type: 'courier',
                                  uri: 'https://api.andreani.com/envios', http_method: 'POST')
        CompanyIntegration.create!(company: company, service: service,
                                   credentials: { 'access_token' => 'SECRET-TOKEN' })
      end

      before { Current.company_id = company.id }

      def code_of_the_call
        Integrations::HttpAdapter.new(company_integration: integration).call
      rescue Integrations::AdapterExecutionError => e
        described_class.code_for(e)
      end

      it 'codes a timeout' do
        stub_request(:post, 'https://api.andreani.com/envios').to_timeout

        expect(code_of_the_call).to eq('INT-006')
      end

      it 'codes a response that is not JSON' do
        stub_request(:post, 'https://api.andreani.com/envios').to_return(status: 200, body: '<')

        expect(code_of_the_call).to eq('INT-009')
      end
    end
  end

  describe '.message_for' do
    it 'answers the cause in words' do
      expect(described_class.message_for('ORD-002'))
        .to eq('La venta trae un producto sin vincular')
    end

    it 'answers nil when there is no code' do
      expect(described_class.message_for(nil)).to be_nil
    end

    it 'reads a code it does not know as an unexpected error' do
      expect(described_class.message_for('XXX-999')).to eq('Error inesperado')
    end
  end

  describe 'the catalog itself' do
    it 'has a message for every code it assigns' do
      expect(described_class::BY_CLASS.values - described_class::MESSAGES.keys).to be_empty
    end

    it 'names only classes that exist' do
      expect(described_class::BY_CLASS.keys.reject(&:safe_constantize)).to be_empty
    end

    it 'keeps every code in the AAA-000 shape' do
      expect(described_class::MESSAGES.keys).to all(match(/\A[A-Z]{3}-\d{3}\z/))
    end
  end

  # Anti-rot: un error nuevo en app/poros tiene que decidir su código. Si no
  # llega nunca a la DLQ, va a la lista de abajo con el motivo; si llega y nadie
  # lo cataloga, el operador lo ve como «Error inesperado».
  describe 'coverage of the errors in app/poros' do
    # Sólo los levantan caminos que responden por HTTP en el momento (un
    # controller los rescata y contesta 4xx): ninguno corre dentro de un job
    # que derive a la DLQ.
    let(:never_in_the_dlq) do
      [
        'Reports::Window::UnknownPeriodError',            # período inválido del reporte → 400
        'Webhooks::RequeueFailedEvent::NotRequeueable',   # reintento manual → 422
        'Orders::OrderNotEditableError',                  # edición o cancelación manual → 409
        'Orders::StaleOrderError',                        # edición con versión vieja → 412
        'Catalog::StaleProductError',                     # edición con versión vieja → 412
        'Catalog::SettleTransfer::NotInFlightError',      # cierre manual de transferencia → 409
        # El despacho manual y la etiqueta (ShipmentsController).
        'Shipments::AlreadyDispatchedError',
        'Shipments::DispatchResponseError',
        'Shipments::DuplicateShipmentError',
        'Shipments::InvalidCourierIntegrationError',
        'Shipments::InvalidShippingCostError',
        'Shipments::LabelResponseError',
        'Shipments::LabelUnavailableError',
        'Shipments::PickupOrderError',
        'Shipments::UnshippableOrderError'
      ]
    end

    def poros_errors
      poros = Rails.root.join('app/poros').to_s
      Rails.autoloaders.main.eager_load_dir(poros)
      ObjectSpace.each_object(Class).select do |klass|
        klass < StandardError && klass.name &&
          Object.const_source_location(klass.name)&.first.to_s.start_with?(poros)
      end.map(&:name)
    end

    it 'finds the errors to check' do
      expect(poros_errors).to include('Catalog::InsufficientStockError')
    end

    it 'catalogues or excludes every error defined in app/poros' do
      uncovered = poros_errors - described_class::BY_CLASS.keys - never_in_the_dlq

      expect(uncovered).to be_empty
    end

    it 'excludes only errors that still exist' do
      expect(never_in_the_dlq.reject(&:safe_constantize)).to be_empty
    end
  end
end
