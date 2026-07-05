class User < ApplicationRecord
  belongs_to :company

  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable,
         :jwt_authenticatable, jwt_revocation_strategy: Devise::JWT::RevocationStrategies::Null

  # Claims extra del JWT: tenant (company_id) y user_id. El encoder agrega
  # sub/exp por su cuenta. Consumidos por el scoping multi-tenant (TESIS-41).
  def jwt_payload
    { 'company_id' => company_id, 'user_id' => id }
  end
end
