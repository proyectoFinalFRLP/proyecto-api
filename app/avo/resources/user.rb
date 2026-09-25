# frozen_string_literal: true

module Avo
  module Resources
    class User < Avo::BaseResource
      self.title = :email
      self.includes = [:company]
      self.search = {
        query: -> { query.where('email ILIKE ?', "%#{search_term}%") }
      }
      # Editar una cuenta sin tocar la password: los campos vacíos no se mandan.
      self.devise_password_optional = true

      def fields
        field :id, as: :id
        field :email, as: :text, required: true
        # Una cuenta no se muda de empresa: el campo no se envía al editar, y si
        # igual llegara un company_id, CompanyScoped rechaza el cambio.
        field :company, as: :belongs_to, disabled: -> { view.edit? }
        password_fields
        field :created_at, as: :date_time, only_on: :index
      end

      def filters
        filter Avo::Filters::CompanyFilter
      end

      private

      # Sin estos campos no había forma de crear un usuario desde el backoffice:
      # Devise exige password y el formulario no la pedía (TESIS-129). Al editar
      # son opcionales y sirven para asignar una nueva.
      def password_fields
        field :password, as: :password, required: -> { view.new? }
        field :password_confirmation, as: :password, required: -> { view.new? }
      end
    end
  end
end
