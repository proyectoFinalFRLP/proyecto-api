# frozen_string_literal: true

require 'rails_helper'

# TESIS-185: hay couriers que sólo entienden los cuatro dígitos del código
# postal, y el sistema acepta también el CPA de ocho caracteres.
RSpec.describe Addresses::ShortPostalCode, type: :poro do
  def short(postal_code) = described_class.call(postal_code)

  {
    'C1414ABC' => '1414',
    'B1842ZAB' => '1842',
    'b1842zab' => '1842',
    ' B 1842 ZAB ' => '1842',
    'X5000' => '5000',
    '1414' => '1414',
    ' 1900 ' => '1900'
  }.each do |postal_code, digits|
    it "reads #{postal_code.inspect} as #{digits.inspect}" do
      expect(short(postal_code)).to eq(digits)
    end
  end

  # Recortar a ciegas cotiza contra otra localidad: lo que no tiene forma de
  # código postal no da ninguno.
  [nil, '', '14', '12345', 'ABCD', 'C1414AB', 'CC1414ABC', '1414-ABC'].each do |postal_code|
    it "answers nil for #{postal_code.inspect}" do
      expect(short(postal_code)).to be_nil
    end
  end

  it 'accepts a number as well as a text' do
    expect(short(1900)).to eq('1900')
  end
end
