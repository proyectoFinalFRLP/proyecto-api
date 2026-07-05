Rails.application.routes.draw do
  # Se conserva el mapping de Devise (:user) para Warden/JWT, sin generar rutas.
  devise_for :users, skip: :all

  get 'up' => 'rails/health#show', as: :rails_health_check

  namespace :api do
    namespace :v1 do
      post 'auth/register', to: 'auth/registrations#create'
      post 'auth/login', to: 'auth/sessions#create'
    end
  end
end
