Rails.application.routes.draw do
  devise_for :users, skip: :all

  get 'up' => 'rails/health#show', as: :rails_health_check

  namespace :api do
    namespace :v1 do
      post 'auth/register', to: 'auth/registrations#create'
      post 'auth/login', to: 'auth/sessions#create'

      resources :integrations, only: %i[index update], param: :service_id
    end
  end
end
