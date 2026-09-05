class User < ApplicationRecord
  include CompanyScoped

  belongs_to :company

  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable,
         :jwt_authenticatable, jwt_revocation_strategy: JwtDenylist

  def jwt_payload
    { 'company_id' => company_id, 'user_id' => id }
  end
end
