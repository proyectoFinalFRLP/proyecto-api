# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20261016115611_replace_product_dimensions_with_measures')

# TESIS-185: cómo se lee el texto libre de las medidas al pasarlo a columnas.
# Lo que no entra en la columna o en la validación del modelo tiene que quedar
# en NULL: si no, el CHECK o el decimal(10,2) abortan el deploy.
RSpec.describe ReplaceProductDimensionsWithMeasures do
  def parse(text) = described_class.new.send(:parse, text)

  it 'reads the three measures with a dot, a comma or a trailing cm', :aggregate_failures do
    expect(parse('16.5x7.8x0.9')).to eq([16.5, 7.8, 0.9].map { BigDecimal(it.to_s) })
    expect(parse('12,5×3×4')).to eq([12.5, 3, 4].map { BigDecimal(it.to_s) })
    expect(parse('10x15x20 cm')).to eq([10, 15, 20].map { BigDecimal(it) })
  end

  it 'leaves out what the column or the model would not take', :aggregate_failures do
    expect(parse('0.004x5x5')).to be_nil
    expect(parse('123456789x1x1')).to be_nil
    expect(parse('20000x1x1')).to be_nil
  end

  it 'leaves out what it does not understand', :aggregate_failures do
    expect(parse('10x15')).to be_nil
    expect(parse('0x5x5')).to be_nil
    expect(parse(nil)).to be_nil
  end
end
