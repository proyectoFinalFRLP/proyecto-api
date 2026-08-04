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
      resources :products, only: %i[index show create update destroy]

      resources :failed_events, path: 'failed-events', only: %i[index] do
        member do
          post :retry, action: :requeue
          post :discard
        end
      end
    end
  end
end
