class QuestsController < ApplicationController
  before_action :set_quest, only: %i[show cancel reopen]

  def index
    scope = Quest.recent
    @status_filter = params[:status].to_s if Quest.statuses.key?(params[:status].to_s)
    scope = scope.where(status: @status_filter) if @status_filter
    @quests = scope.limit(100)
  end

  def show
    @new_instruction = @quest.instructions.build
  end

  def new
    @form = QuestForm.new
  end

  def create
    @form = QuestForm.new(quest_form_params)

    if @form.valid?
      instruction = Quest.start!(title: @form.title, body: @form.body, source_platform: "dashboard")
      redirect_to instruction.quest, notice: "Quest を作成しました。"
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
