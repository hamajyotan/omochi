class Quests::InstructionsController < ApplicationController
  def create
    @quest = Quest.find_by_public_id!(params[:quest_id])
    @quest.receive_instruction!(body: params.expect(quest_instruction: [ :body ])[:body], source_platform: "dashboard")
    redirect_to @quest, notice: "指示を受け付けました。"
  rescue ActiveRecord::RecordInvalid => error
    redirect_to @quest, alert: "指示を受け付けられませんでした: #{error.record.errors.full_messages.to_sentence}"
  rescue Quest::InstructionQueue::InstructionRejected => error
    redirect_to @quest, alert: "指示を受け付けられませんでした: #{error.message}"
  end
end
