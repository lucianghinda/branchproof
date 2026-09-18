# frozen_string_literal: true

Rails.application.routes.draw do
  resources :fixture_records, only: %i[show create]
end
