# frozen_string_literal: true

class AddCategoryToProducts < ActiveRecord::Migration[8.1]
  def change
    add_column :products, :category, :string

    # El listado del catálogo filtra por categoría dentro de una empresa, y el
    # default_scope de CompanyScoped ya pone company_id en el WHERE: el índice
    # compuesto sirve a esa consulta y no uno sobre category sola.
    add_index :products, %i[company_id category]
  end
end
