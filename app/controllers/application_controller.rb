class ApplicationController < ActionController::API
  before_action :authenticate_user!
  before_action :set_current_tenant

  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found

  private

  def set_current_tenant
    Current.company_id = current_user&.company_id
    Current.user = current_user
  end

  def render_not_found
    render json: { error: 'Not found' }, status: :not_found
  end
end
