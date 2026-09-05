# frozen_string_literal: true

# Tokens revocados. La estrategia de devise-jwt inserta una fila al cerrar sesión
# y consulta esta tabla en cada request autenticado.
#
# No incluye CompanyScoped a propósito: es una tabla global, como `services`. El
# token identifica a un usuario, y filtrar por empresa dejaría a un token revocado
# pasando el chequeo desde otro contexto de tenant.
class JwtDenylist < ApplicationRecord
  include Devise::JWT::RevocationStrategies::Denylist

  self.table_name = 'jwt_denylist'

  # Los tokens vencidos ya no autentican, así que su fila no aporta nada y sólo
  # hace crecer la tabla. La limpieza periódica usa este scope.
  scope :expired, -> { where(exp: ...Time.current) }
end
