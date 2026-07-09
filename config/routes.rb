Rails.application.routes.draw do
  devise_for :users, skip: :all

  get 'up' => 'rails/health#show', as: :rails_health_check

  namespace :admin do
    # En modo API-only, resources omite new/edit por defecto: se listan explícito.
    resources :services, only: %i[index show new create edit update]
  end

  namespace :api do
    namespace :v1 do
      post 'auth/register', to: 'auth/registrations#create'
      post 'auth/login', to: 'auth/sessions#create'
    end
  end
end
