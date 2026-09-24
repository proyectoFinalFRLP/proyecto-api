# frozen_string_literal: true

module Avo
  module Resources
    class Company < Avo::BaseResource
      self.title = :name
      self.includes = []
      # `q` y no `search_term`: es el nombre con el que Avo 4 entrega lo tipeado
      # al lambda (`Avo::ExecutionContext.new(..., q: params[:q])`). Con el otro
      # nombre, buscar en el panel levanta NameError (TESIS-93).
      self.search = {
        query: lambda {
          query.where('name ILIKE ? OR slug ILIKE ? OR tax_id ILIKE ?', "%#{q}%",
                      "%#{q}%", "%#{q}%")
        }
      }

      def fields
        field :id, as: :id
        field :name, as: :text, required: true
        field :slug, as: :text, required: true
        field :tax_id, as: :text, required: true
        field :is_active, as: :boolean
        field :branding, as: :code, language: 'json', only_on: %i[show forms],
                         format_using: -> { JSON.pretty_generate(value || {}) }
        field :features, as: :code, language: 'json', only_on: %i[show forms],
                         format_using: -> { JSON.pretty_generate(value || {}) }
        field :users, as: :has_many
        field :warehouses, as: :has_many
        field :products, as: :has_many
        field :company_integrations, as: :has_many, name: 'Integrations'
      end
    end
  end
end
