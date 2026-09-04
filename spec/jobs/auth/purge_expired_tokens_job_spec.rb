# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Auth::PurgeExpiredTokensJob, type: :job do
  def expired_entry
    JwtDenylist.create!(jti: SecureRandom.uuid, exp: 1.hour.ago)
  end

  it 'deletes the entries whose token already expired' do
    expired_entry
    expect { described_class.new.perform }.to change(JwtDenylist, :count).by(-1)
  end

  it 'keeps the entries of tokens still alive' do
    JwtDenylist.create!(jti: SecureRandom.uuid, exp: 1.hour.from_now)
    expect { described_class.new.perform }.not_to change(JwtDenylist, :count)
  end

  # El barrido borra en lotes para no bloquear la tabla entera, pero tiene que
  # seguir iterando: con un solo lote la tabla dejaba de bajar apenas hubiera
  # mas vencidos que BATCH_SIZE en un dia, que es justo lo que este job existe
  # para evitar.
  it 'keeps going past the first batch' do
    stub_const("#{described_class}::BATCH_SIZE", 2)
    3.times { expired_entry }

    expect { described_class.new.perform }.to change(JwtDenylist, :count).by(-3)
  end

  # Techo de la corrida: sin el, un error de conteo dejaria el job iterando para
  # siempre. Lo que quede lo levanta la corrida del dia siguiente.
  it 'stops at the ceiling instead of looping forever' do
    stub_const("#{described_class}::BATCH_SIZE", 1)
    stub_const("#{described_class}::MAX_BATCHES", 2)
    3.times { expired_entry }

    expect { described_class.new.perform }.to change(JwtDenylist, :count).by(-2)
  end

  # La tabla es global: JwtDenylist no incluye CompanyScoped porque la
  # revocacion es del token y no del inquilino. Con un tenant en contexto el
  # barrido tiene que borrar igual — si alguien le agregara el concern, este
  # ejemplo cae.
  it 'purges regardless of the tenant in context' do
    company = Company.create!(name: 'Acme', tax_id: '30-11111111-1')
    expired_entry

    Current.set(company_id: company.id) do
      expect { described_class.new.perform }.to change(JwtDenylist, :count).by(-1)
    end
  end
end
