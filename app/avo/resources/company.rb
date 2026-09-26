# frozen_string_literal: true

module Avo
  module Resources
    class Company < Avo::BaseResource
      self.title = :name
      self.includes = []
      # Avo 4 le pasa el texto buscado como `q`. `search_term` no existe en ese
      # contexto, y con él la búsqueda respondía 500 (TESIS-129).
      self.search = {
        query: lambda {
          query.where('name ILIKE :term OR slug ILIKE :term OR tax_id ILIKE :term', term: "%#{q}%")
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
