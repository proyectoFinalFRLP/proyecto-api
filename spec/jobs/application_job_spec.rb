# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplicationJob, type: :job do
  # Job de prueba: ejercita la base sin depender de un job de producción.
  let(:job_class) do
    Class.new(described_class) do
      queue_as :realtime

      cattr_accessor :seen_company_id, :runs

      # fail_with viaja como String: los argumentos de un job deben ser
      # serializables para poder reencolarse en un reintento.
      def perform(company_id: nil, fail_with: nil)
        raise Integrations::AdapterExecutionError, 'API caída' if fail_with == 'adapter'
        raise 'bug del programador' if fail_with == 'runtime'

        with_tenant(company_id) { self.class.seen_company_id = Current.company_id }
        self.class.runs = self.class.runs.to_i + 1
      end
    end
  end
  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }

  before do
    stub_const('TenantAwareTestJob', job_class)
    job_class.seen_company_id = nil
    job_class.runs = 0
  end

  after { Current.reset }

  describe 'queues' do
    it 'declares the queues configured in queue.yml' do
      expect(described_class::QUEUES).to eq(%i[realtime default low])
    end

    it 'enqueues into the queue chosen by the job' do
      expect { TenantAwareTestJob.perform_later }.to have_enqueued_job.on_queue('realtime')
    end
  end

  describe 'tenant context' do
    it 'activates the given tenant while performing' do
      TenantAwareTestJob.perform_now(company_id: company.id)
      expect(job_class.seen_company_id).to eq(company.id)
    end

    it 'clears the tenant after performing so threads do not leak context' do
      TenantAwareTestJob.perform_now(company_id: company.id)
      expect(Current.company_id).to be_nil
    end

    it 'clears the tenant even when the job raises' do
      Current.company_id = company.id
      suppress(RuntimeError) { TenantAwareTestJob.perform_now(fail_with: 'runtime') }
      expect(Current.company_id).to be_nil
    end
  end

  describe 'retries' do
    it 'retries external API failures instead of dropping the job' do
      expect { TenantAwareTestJob.perform_now(fail_with: 'adapter') }
        .to have_enqueued_job(TenantAwareTestJob)
    end

    it 'waits longer between attempts instead of hammering the failing service' do
      expect { TenantAwareTestJob.perform_now(fail_with: 'adapter') }
        .to have_enqueued_job(TenantAwareTestJob).at(a_value > Time.current)
    end

    it 'does not retry unexpected errors' do
      expect { TenantAwareTestJob.perform_now(fail_with: 'runtime') }
        .to raise_error(RuntimeError)
    end
  end
end
