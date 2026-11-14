Rails.application.routes.draw do
  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  get "up" => "rails/health#show", as: :rails_health_check

  # Quest URLs use the public Quest ID (qst_...), never the internal primary key.
  resources :quests, only: %i[index show new create] do
    resources :instructions, only: :create, module: :quests
  end

  root "quests#index"
end
