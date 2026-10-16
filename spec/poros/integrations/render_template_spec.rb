# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Integrations::RenderTemplate, type: :poro do
  include ActiveSupport::Testing::TimeHelpers

  let(:values) do
    { 'name' => 'José Pérez & "Hijos"', 'weight' => BigDecimal('2.50'), 'volume' => 0.000008,
      'total' => BigDecimal('15000.00'), 'street' => 'Avenida de los Constituyentes',
      'empty' => '', 'nothing' => nil }
  end
  let(:resolver) { ->(name) { [values.key?(name), values[name]] } }

  def render(template, **options)
    described_class.new(template: template, resolver: resolver, **options).call
  end

  it 'replaces the variables' do
    expect(render('Hola {{ street }}')).to eq([true, 'Hola Avenida de los Constituyentes'])
  end

  it 'writes decimals with a dot, without exponent and without a useless .0', :aggregate_failures do
    expect(render('{{weight}}|{{total}}|{{volume}}')).to eq([true, '2.5|15000|0.000008'])
  end

  describe 'filters' do
    it 'truncates to the given length' do
      expect(render('{{street|truncate:10}}').last).to eq('Avenida de')
    end

    it 'falls back to the default when the value is missing or empty', :aggregate_failures do
      expect(render('{{nothing|default:0}}').last).to eq('0')
      expect(render('{{empty|default:S/N}}').last).to eq('S/N')
      expect(render('{{unknown|default:}}').last).to eq('')
    end

    it 'formats today and now with strftime' do
      travel_to(Time.zone.local(2026, 10, 16, 9, 30)) do
        expect(render('{{today|date:%Y%m%d}} {{now|date:%H:%M}}').last).to eq('20261016 09:30')
      end
    end

    it 'drops accents and eñes with ascii' do
      values['name'] = 'Muñoz Pérez'
      expect(render('{{name|ascii}}').last).to eq('Munoz Perez')
    end

    it 'chains filters in the order they are written' do
      expect(render('{{nothing|default:Calle larguísima|truncate:5}}').last).to eq('Calle')
    end

    it 'rejects an unknown filter' do
      expect { render('{{name|shout}}') }.to raise_error(described_class::UnknownFilterError)
    end
  end

  describe 'missing variables' do
    it 'renders nothing when strict' do
      expect(render('id-{{nothing}}')).to eq([false, nil])
    end

    it 'leaves the variable empty when lenient' do
      expect(render('<a piso="{{nothing}}"/>', strict: false)).to eq([true, '<a piso=""/>'])
    end
  end

  describe 'XML escaping' do
    it 'escapes every value but not the template' do
      expect(render('<a n="{{name}}"/>', escape: :xml).last)
        .to eq('<a n="José Pérez &amp; &quot;Hijos&quot;"/>')
    end

    it 'leaves a raw value as it is' do
      expect(render('{{name|raw}}', escape: :xml).last).to eq('José Pérez & "Hijos"')
    end
  end
end
