class QuestsController < ApplicationController
  def index
    @quests = Quest.recent.limit(100)
  end

  def show
    @quest = Quest.find_by_public_id!(params[:id])
    @instructions = @quest.instructions.includes(:external_resource)
    @executions = @quest.executions.includes(:instruction)
    @external_resources = @quest.external_resources.order(:id)
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

  private
    def quest_form_params
      params.expect(quest_form: %i[title body])
    end
end
