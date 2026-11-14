# Form object for creating a Quest from the Dashboard (title + first instruction).
# Composes the Quest and its initial QuestInstruction models using active_record_compose.
class QuestForm < ActiveRecordCompose::Model
  def initialize(attributes = {})
    @quest = Quest.new
    @instruction = @quest.instructions.build(
      sequence: 1,
      source_platform: "dashboard",
      received_at: Time.current
    )
    super(attributes)
    models.push(@quest)
    models.push(@instruction)
  end

  attr_reader :quest, :instruction

  delegate_attribute :title, to: :quest
  delegate_attribute :body, to: :instruction

  after_commit do
    quest.broadcast_dashboard_updates
    quest.enqueue_processing
  end
end
