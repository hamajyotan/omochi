class Quests::InstructionsController < ApplicationController
  before_action :set_quest

  def create
    @quest.receive_instruction!(body: params.expect(quest_instruction: [ :body ])[:body], source_platform: "dashboard")
    redirect_to @quest, notice: "指示を受け付けました。"
  rescue ActiveRecord::RecordInvalid => error
    redirect_to @quest, alert: "指示を受け付けられませんでした: #{error.record.errors.full_messages.to_sentence}"
  rescue Quest::InstructionQueue::InstructionRejected => error
    redirect_to @quest, alert: "指示を受け付けられませんでした: #{error.message}"
  end

  def retry
    instruction = @quest.instructions.find(params[:id])
    instruction.retry!
    redirect_to @quest, notice: "Instruction ##{instruction.sequence} を再キューイングしました。"
  rescue QuestInstruction::CannotRetry => error
    redirect_to @quest, alert: "再試行できませんでした: #{error.message}"
  end

  private
    def set_quest
      @quest = Quest.find_by_public_id!(params[:quest_id])
    end
end
