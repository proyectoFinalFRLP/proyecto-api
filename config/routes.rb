Rails.application.routes.draw do
  devise_for :admin_users, path: 'admin', controllers: { sessions: 'admin/sessions' }
  mount_avo
  devise_for :users, skip: :all

  get 'up' => 'rails/health#show', as: :rails_health_check

  namespace :api do
    namespace :v1 do
      post 'auth/register', to: 'auth/registrations#create'
      post 'auth/login', to: 'auth/sessions#create'
      delete 'auth/logout', to: 'auth/sessions#destroy'

      # Ruta pública: el frontend la pide antes del login para resolver branding
      # y feature flags del tenant (por header X-Tenant-Slug o ?slug=).
      get 'tenant-config', to: 'tenant_config#show'

      # La identidad de la sesión. Sin id por parámetro: siempre el usuario
      # del token.
      get 'me', to: 'me#show'

      resources :integrations, only: %i[index update], param: :service_id
      resources :warehouses, only: %i[index show create update destroy]
      resources :products, only: %i[index show create update destroy] do
        # Vocabulario de categorías: ruta de colección, no depende de un producto.
        get :categories, on: :collection

        resources :mappings, only: %i[index create destroy], controller: 'product_mappings'
      end

      resources :stock_transfers, path: 'stock-transfers', only: %i[index create] do
        member do
          post :receive
          post :cancel
        end
      end

      resources :orders, only: %i[create] do
        resources :quotes, only: %i[create], controller: 'shipment_quotes'
      end

      resources :failed_events, path: 'failed-events', only: %i[index] do
        member do
          post :retry, action: :requeue
          post :discard
        end
      end
    end

    # Ruta pública: la consumen las plataformas externas, no el frontend.
    namespace :webhooks do
      post 'integrations/:company_integration_id', to: 'integrations#create'
      post 'couriers/:company_integration_id', to: 'couriers#create'
    end
  end
end
