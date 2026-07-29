Rails.application.routes.draw do
  devise_for :admin_users, path: 'admin', controllers: { sessions: 'admin/sessions' }
  mount_avo
  devise_for :users, skip: :all

  get 'up' => 'rails/health#show', as: :rails_health_check

  namespace :api do
    namespace :v1 do
      post 'auth/register', to: 'auth/registrations#create'
      post 'auth/login', to: 'auth/sessions#create'

      resources :integrations, only: %i[index update], param: :service_id
    end

    # Ruta pública: la consumen las plataformas externas, no el frontend.
    namespace :webhooks do
      post 'integrations/:company_integration_id', to: 'integrations#create'
    end
  end
end
