# frozen_string_literal: true

class FixtureRecordsController < ActionController::Base
  skip_forgery_protection

  def show
    @record = FixtureRecord.find(params[:id])
    render :show
  end

  def create
    @record = FixtureRecordService.call(name: params.fetch(:name), enabled: params[:enabled] != "false")
    redirect_to fixture_record_path(@record)
  end
end
