require "test_helper"

class QuestFormTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "composes Quest and initial QuestInstruction on save" do
    form = QuestForm.new(title: "Composed Quest", body: "First instruction from form")

    assert form.valid?
    assert_enqueued_with(job: QuestProcessingJob) do
      assert form.save
    end

    assert form.quest.persisted?
    assert form.instruction.persisted?
    assert_equal "Composed Quest", form.quest.title
    assert_equal "First instruction from form", form.instruction.body
    assert_equal 1, form.instruction.sequence
    assert_equal "dashboard", form.instruction.source_platform
    assert_equal form.quest.id, form.instruction.quest_id
  end

  test "validates attributes via composed models" do
    form = QuestForm.new(title: "", body: "")

    assert_not form.valid?
    assert form.errors.of_kind?(:title, :blank)
    assert form.errors.of_kind?(:body, :blank)
  end

  test "fails and rolls back if one of the models cannot be saved" do
    form = QuestForm.new(title: "Valid Title", body: "Valid Body")
    # Invalidate sequence uniqueness or make body invalid right before saving
    form.instruction.sequence = nil

    assert_no_difference [ -> { Quest.count }, -> { QuestInstruction.count } ] do
      assert_not form.save
    end
    assert_not form.quest.persisted?
  end
end
