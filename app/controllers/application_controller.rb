class ApplicationController < ActionController::API
  include Pundit::Authorization

  before_action :authenticate_user!
  before_action :set_current_tenant

  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
  rescue_from ActiveRecord::RecordInvalid, with: :render_unprocessable
  # dependent: :restrict_with_error (ej. producto con order_items) -> 409. Los
  # controllers que quieran un mensaje específico declaran su propio rescue_from
  # (ej. warehouses_controller con su render_conflict).
  rescue_from ActiveRecord::RecordNotDestroyed, with: :render_not_destroyable
  rescue_from Pundit::NotAuthorizedError, with: :render_forbidden
  # El bloqueo de stock lo van a usar varios controllers (productos, órdenes),
  # así que el mapeo vive acá y no en cada uno. ProductsController define su
  # propio render_conflict para RecordNotUnique, que es otra cosa: por eso
  # este handler tiene su propio método.
  rescue_from Catalog::LockTimeoutError, with: :render_lock_conflict
  rescue_from ActiveRecord::CheckViolation, with: :render_constraint_violation

  # Las acciones index usan policy_scope; el resto deben llamar authorize.
  # Si una acción futura olvida el authorize, falla en vez de pasar sin ruido.
  #
  # La condición va por predicado y no por `only:`/`except: :index`. Desde
  # Rails 7.1, nombrar en `only:`/`except:` una acción que el controller no
  # define levanta AbstractController::ActionNotFound — y como `index` se define
  # en las subclases, cualquier controller sin index se caía con un 404 engañoso
  # antes de ejecutar su acción. Lo pisó primero la cotización de TESIS-46, que
  # tiene una sola acción. Con el predicado el comportamiento es idéntico y deja
  # de ser una trampa para el próximo controller de acción única. De paso ya no
  # hace falta silenciar Rails/LexicallyScopedActionFilter.
  after_action :verify_authorized, unless: :index_action?
  after_action :verify_policy_scoped, if: :index_action?

  private

  def index_action? = action_name == 'index'

  def set_current_tenant
    Current.company_id = current_user&.company_id
    Current.user = current_user
  end

  # Compartido por los controllers de la API v1 (integrations, products,
  # warehouses): el tenant siempre sale del JWT, nunca del body.
  def current_company
    current_user.company
  end

  def render_not_found
    render json: { error: 'Not found' }, status: :not_found
  end

  def render_forbidden
    render json: { error: 'Forbidden' }, status: :forbidden
  end

  def render_unprocessable(exception)
    render json: { error: exception.message }, status: :unprocessable_content
  end

  def render_lock_conflict(exception)
    render json: { error: exception.message }, status: :conflict
  end

  # Última línea de defensa: en los caminos normales la validación de Stock ya
  # devuelve 422 vía RecordInvalid, así que acá sólo llegan las escrituras que
  # se saltean las validaciones del modelo (update_all, upsert_all, SQL crudo).
  # Para el resto de los CHECK se responde genérico a propósito: el mensaje de
  # PostgreSQL nombra tabla y restricción, y no hay por qué filtrarlo.
  def render_constraint_violation(exception)
    message = if exception.message.include?('stocks_quantity_non_negative')
                'stock quantity cannot be negative'
              else
                'invalid data: a database constraint was violated'
              end

    render json: { error: message }, status: :unprocessable_content
  end

  def render_not_destroyable
    render json: { error: 'Cannot delete record with dependent data' }, status: :conflict
  end
end
