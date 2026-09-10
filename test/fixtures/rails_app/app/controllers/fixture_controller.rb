# frozen_string_literal: true

class FixtureController < ActionController::Base
  def show
    render plain: FixtureDecisionService.new.choose(params[:value].to_i).to_s
  end
end
