# frozen_string_literal: true

require 'rails_helper'

# La base de todos los casos de uso (TESIS-93).
#
# Sólo aporta el atajo de clase `.call`, que evita el `new(...).call` en cada
# invocación. Nadie lo usaba —todos los llamadores escriben las dos partes—, así
# que era código sin un solo ejemplo: si se rompiera, se enteraría el primero
# que lo use.
RSpec.describe ApplicationPoro, type: :poro do
  let(:greeter) do
    Class.new(described_class) do
      def initialize(name:, greeting: 'Hola')
        super()
        @name = name
        @greeting = greeting
      end

      def call = "#{@greeting}, #{@name}"
    end
  end

  let(:adder) do
    Class.new(described_class) do
      def initialize(first, second)
        super()
        @first = first
        @second = second
      end

      def call = @first + @second
    end
  end

  it 'builds the instance and runs it in one step' do
    expect(greeter.call(name: 'Ana')).to eq('Hola, Ana')
  end

  it 'forwards every keyword to the constructor' do
    expect(greeter.call(name: 'Ana', greeting: 'Buen día')).to eq('Buen día, Ana')
  end

  it 'returns what the instance returns, not the instance' do
    expect(greeter.call(name: 'Ana')).to be_a(String)
  end

  it 'forwards positional arguments too' do
    expect(adder.call(2, 3)).to eq(5)
  end
end
