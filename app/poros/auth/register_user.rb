# frozen_string_literal: true

module Auth
  class RegisterUser < ApplicationPoro
    def initialize(params:, company:)
      super()
      @params = params
      @company = company
    end

    # La company es la que resolvió el slug del request, nunca la que venga en
    # el body: hasta TESIS-120 `company_id` era un parámetro permitido y con eso
    # cualquiera podía darse de alta dentro de cualquier tenant.
    #
    # El `Current.set` no es decorativo: User incluye CompanyScoped, que en el
    # create pisa `company_id` con `Current.company_id` si está seteado. Sin
    # esto, un register con un JWT de otro tenant en el header crearía el
    # usuario en ese otro tenant en vez de en el del slug.
    def call
      Current.set(company_id: @company.id) do
        User.create!(@params.merge(company: @company))
      end
    end
  end
end
