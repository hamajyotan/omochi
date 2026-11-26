class QuestsController < ApplicationController
  DEFAULT_PER_PAGE = 20

  before_action :set_quest, only: %i[show cancel reopen]

  def index
    scope = Quest.recent
    @status_filter = params[:status].to_s if Quest.statuses.key?(params[:status].to_s)
    scope = scope.where(status: @status_filter) if @status_filter

    @per_page = DEFAULT_PER_PAGE
    @total_count = scope.count
    @total_pages = [ (@total_count.to_f / @per_page).ceil, 1 ].max

    requested_page = params[:page].to_i
    @page = requested_page > 0 ? requested_page : 1
    @page = @total_pages if @page > @total_pages

    @quests = scope.offset((@page - 1) * @per_page).limit(@per_page)
  end

  def show
    @new_instruction = @quest.instructions.build
  end

  def new
    @form = QuestForm.new
  end

  def create
    @form = QuestForm.new(quest_form_params)

    if @form.save
      redirect_to @form.quest, notice: "Quest を作成しました。"
    else
      render :new, status: :unprocessable_content
    end
  end

  def cancel
    @quest.cancel!
    redirect_to @quest, notice: "Quest をキャンセルしました。"
  end

  def reopen
    @quest.reopen!
    redirect_to @quest, notice: "Quest を再開しました。"
  end

  private
    def set_quest
      @quest = Quest.find_by_public_id!(params[:id])
    end

    def quest_form_params
      params.expect(quest_form: %i[title body])
    end
end
