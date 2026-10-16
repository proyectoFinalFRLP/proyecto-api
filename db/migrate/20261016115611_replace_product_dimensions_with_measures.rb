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
  # alrededor. Nada más: '10x15' o '10x15x20 cm' no se reconocen.
  NUMBER = '\s*(\d+(?:[.,]\d+)?)\s*'
  PATTERN = /\A#{NUMBER}[xX×]#{NUMBER}[xX×]#{NUMBER}\z/

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

    measures = match.captures.map { |value| BigDecimal(value.tr(',', '.')) }
    measures.all?(&:positive?) ? measures : nil
  end

  # '16.5' y no '16.50': el texto vuelve como se escribía.
  def format_measure(value)
    value.to_d.to_s('F').delete_suffix('.0')
  end
end
