# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Integrations::TranslateResponseValue, type: :poro do
  let(:mapper) do
    { 'Entregado' => 'delivered', 'En Tránsito' => 'in_transit', 'Visita*' => 'in_transit',
      'Estado de Visita ONLINE*' => 'in_transit',
      'Estado de Visita ONLINE (Entregado)*' => 'delivered' }
  end

  def translate(value) = described_class.new(mapper: mapper, value: value).call

  it 'finds the exact key first' do
    expect(translate('Entregado')).to eq([true, 'delivered'])
  end

  it 'ignores case, accents and repeated spaces' do
    expect(translate('EN  TRANSITO')).to eq([true, 'in_transit'])
  end

  it 'matches a key ending in * as a prefix' do
    expect(translate('Visita - Domicilio cerrado')).to eq([true, 'in_transit'])
  end

  it 'prefers the longest prefix' do
    expect(translate('Estado de Visita ONLINE (Entregado) - Firma')).to eq([true, 'delivered'])
  end

  it 'does not use a plain key as a prefix' do
    expect(translate('Entregado parcialmente')).to eq([false, nil])
  end

  it 'says when nothing matches' do
    expect(translate('Desconocido')).to eq([false, nil])
  end

  # Un JSON en Latin-1 deja bytes que no son UTF-8: antes `fetch` no los
  # encontraba y ya, con la normalización levantaba ArgumentError.
  it 'does not fail on bytes that are not valid UTF-8' do
    expect(translate("EN TR\xC1NSITO".b.force_encoding('UTF-8'))).to eq([false, nil])
  end
end
