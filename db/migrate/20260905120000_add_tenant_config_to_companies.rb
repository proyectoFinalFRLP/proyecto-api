# frozen_string_literal: true

# TESIS-120 — Config de tenant en la tabla global `companies`.
#
# `slug` es el identificador estable del tenant (el subdominio con el que el
# frontend se presenta). `features` y `branding` son jsonb para que agregar un
# flag o un token de branding no vuelva a ser una migración.
class AddTenantConfigToCompanies < ActiveRecord::Migration[8.1]
  def up
    add_column :companies, :slug, :string
    add_column :companies, :features, :jsonb, default: {}, null: false
    add_column :companies, :branding, :jsonb, default: {}, null: false

    backfill_slugs

    change_column_null :companies, :slug, false
    add_index :companies, :slug, unique: true
  end

  def down
    remove_index :companies, :slug
    remove_column :companies, :branding
    remove_column :companies, :features
    remove_column :companies, :slug
  end

  private

  # Las companies que ya existen necesitan un slug antes de que la columna pase
  # a NOT NULL. Se deriva del nombre y, si dos nombres colapsan al mismo slug,
  # se desempata con el id (que es único por definición).
  #
  # Se usa una clase anónima en vez de `Company` a propósito: una migración no
  # debe depender de las validaciones ni de los scopes que el modelo tenga hoy.
  def backfill_slugs
    model = Class.new(ActiveRecord::Base) { self.table_name = 'companies' }
    taken = model.where.not(slug: nil).pluck(:slug).to_set

    model.where(slug: nil).order(:id).each do |company|
      base = company.name.to_s.parameterize.presence || "company-#{company.id}"
      slug = taken.include?(base) ? "#{base}-#{company.id}" : base
      taken << slug
      company.update_columns(slug: slug)
    end
  end
end
