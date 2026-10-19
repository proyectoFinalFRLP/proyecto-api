# frozen_string_literal: true

# Las medidas del producto pasan de un texto libre ('16.5x7.8x0.9') a tres
# números en centímetros (TESIS-185). Un courier cotiza por volumen, y un texto
# que cada operador escribe a su manera no se puede multiplicar.
#
# Nullable porque no todos los productos tienen medidas cargadas, y un cero
# sería inventarlas. El CHECK es el último garante de lo que valida el modelo:
# una medida cargada es positiva.
#
# El backfill parsea lo que ya había con la forma «largo x ancho x alto». Lo
# que no se entiende queda en NULL en vez de adivinarse: el texto se pierde,
# pero es preferible a una medida falsa con la que se cotiza mal.
class ReplaceProductDimensionsWithMeasures < ActiveRecord::Migration[8.1]
  MEASURES = %i[length_cm width_cm height_cm].freeze

  # Tres números separados por x, X o ×, con coma o punto decimal y espacios
  # alrededor, y opcionalmente `cm` al final, que es como mucha gente lo
  # escribe. Nada más: '10x15' no se reconoce.
  NUMBER = '\s*(\d+(?:[.,]\d+)?)\s*'
  PATTERN = /\A#{NUMBER}[xX×]#{NUMBER}[xX×]#{NUMBER}(?:cm)?\s*\z/i

  # Lo que entra en la columna y pasa la validación del modelo
  # (`Product::MAX_MEASURE_CM`), copiado y no leído del modelo: la migración no
  # depende de él. Fuera de ese rango el texto queda en NULL, como el que no se
  # entiende: un 0,004 se redondearía a 0,00 y rompería el CHECK, y un número
  # enorme no entra en decimal(10,2). Cualquiera de los dos abortaba el deploy.
  MIN_MEASURE = BigDecimal('0.01')
  MAX_MEASURE = 10_000

  # Modelo propio de la migración: no depende de las validaciones ni del
  # default_scope por tenant de `Product`, que pueden cambiar después.
  class MigrationProduct < ActiveRecord::Base
    self.table_name = 'products'
  end

  def up
    MEASURES.each { |column| add_column :products, column, :decimal, precision: 10, scale: 2 }
    MEASURES.each do |column|
      add_check_constraint :products, "#{column} > 0", name: "products_#{column}_positive"
    end

    MigrationProduct.reset_column_information
    MigrationProduct.where.not(dimensions: nil).find_each do |product|
      measures = parse(product.dimensions)
      product.update_columns(MEASURES.zip(measures).to_h) if measures
    end

    remove_column :products, :dimensions
  end

  # La vuelta rearma el texto con las tres medidas, en el mismo orden. Un
  # producto con alguna medida faltante queda sin texto: «10x?x20» no es lo
  # que había.
  def down
    add_column :products, :dimensions, :string

    MigrationProduct.reset_column_information
    MigrationProduct.where.not(length_cm: nil).where.not(width_cm: nil).where.not(height_cm: nil)
                    .find_each do |product|
      text = MEASURES.map { |column| format_measure(product[column]) }.join('x')
      product.update_columns(dimensions: text)
    end

    MEASURES.each do |column|
      remove_check_constraint :products, name: "products_#{column}_positive"
      remove_column :products, column
    end
  end

  private

  # Una medida en cero tampoco entra: el CHECK la rechazaría.
  def parse(text)
    match = PATTERN.match(text.to_s.strip)
    return nil if match.nil?

    measures = match.captures.map { |value| BigDecimal(value.tr(',', '.')).round(2) }
    measures.all? { |measure| measure.between?(MIN_MEASURE, MAX_MEASURE) } ? measures : nil
  end

  # '16.5' y no '16.50': el texto vuelve como se escribía.
  def format_measure(value)
    value.to_d.to_s('F').delete_suffix('.0')
  end
end
