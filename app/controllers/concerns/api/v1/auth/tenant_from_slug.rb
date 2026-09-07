# frozen_string_literal: true

module Api
  module V1
    module Auth
      # Resolución de tenant para los endpoints de auth, que corren sin sesión.
      #
      # El slug viaja **sólo** por header: aceptarlo también por query param
      # dejaría el tenant de un login en la URL, que se loguea y queda en el
      # historial. El query param existe únicamente en `GET /tenant-config`,
      # como comodidad de debug.
      #
      # Esto no es tenancy por header: estos dos endpoints son los únicos que no
      # tienen JWT del cual sacar el tenant. En todo endpoint autenticado la
      # fuente de aislamiento sigue siendo `Current.company_id` (ADR-003).
      module TenantFromSlug
        extend ActiveSupport::Concern

        private

        def tenant_company
          ::Auth::ResolveTenant.new(slug: request.headers['X-Tenant-Slug']).call
        end
      end
    end
  end
end
