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

        # `resource` en singular: la restricción 1 a 1 de TESIS-45 (índice único
        # sobre shipments.order_id) hace que la orden tenga a lo sumo un envío,
        # así que no hay id que poner en la URL.
        resource :shipment, only: %i[create]
      end

      # El alta cuelga de la orden (POST /orders/:order_id/shipment, arriba): un
      # envío nace siempre de una. Acá quedan la lista y el detalle, que se leen
      # por envío. El filtro por orden viaja como query param (?order_id=) y no
      # como ruta anidada: el listado es la vista principal, y la orden es un
      # filtro más.
      resources :shipments, only: %i[index show]

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
