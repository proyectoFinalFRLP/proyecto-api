class ApplicationController < ActionController::API
  include Pundit::Authorization

  before_action :authenticate_user!
  before_action :set_current_tenant

  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
  rescue_from Pundit::NotAuthorizedError, with: :render_forbidden

  # Las acciones index usan policy_scope; el resto deben llamar authorize.
  # Si una acción futura olvida el authorize, falla en vez de pasar sin ruido.
  # `index` se define en las subclases, no en esta clase: el cop
  # Rails/LexicallyScopedActionFilter no puede resolverla y se excluye acá.
  # rubocop:disable Rails/LexicallyScopedActionFilter
  after_action :verify_authorized, except: :index
  after_action :verify_policy_scoped, only: :index
  # rubocop:enable Rails/LexicallyScopedActionFilter

  private

  def set_current_tenant
    Current.company_id = current_user&.company_id
    Current.user = current_user
  end

  def render_not_found
    render json: { error: 'Not found' }, status: :not_found
  end

  def render_forbidden
    render json: { error: 'Forbidden' }, status: :forbidden
  end
end
