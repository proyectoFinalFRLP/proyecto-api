# frozen_string_literal: true

module Avo
  module Resources
    class User < Avo::BaseResource
      self.title = :email
      self.includes = [:company]
      # Ver el comentario de Avo::Resources::Company: el término tipeado llega
      # como `q` (TESIS-93).
      self.search = {
        query: -> { query.where('email ILIKE ?', "%#{q}%") }
      }

      def fields
        field :id, as: :id
        field :email, as: :text, required: true
        field :company, as: :belongs_to
        field :created_at, as: :date_time, only_on: :index
      end

      def filters
        filter Avo::Filters::CompanyFilter
      end
    end
  end
end
