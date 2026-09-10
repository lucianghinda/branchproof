# frozen_string_literal: true

Rails.application.routes.draw do
  get "/fixture", to: "fixture#show"
end
