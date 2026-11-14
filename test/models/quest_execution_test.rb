require "test_helper"

class QuestExecutionTest < ActiveSupport::TestCase
  setup do
    @quest = start_quest
    @execution = @quest.claim_next_instruction!
  end

  test "walks through the lifecycle" do
    @execution.mark_preparing!
    @execution.mark_running!
    assert_not_nil @execution.started_at

    assert @execution.succeed!(result_summary: "done")
    assert @execution.succeeded?
    assert_not_nil @execution.finished_at
    assert_equal "done", @execution.result_summary
    assert_operator @execution.duration, :>=, 0
  end

  test "rejects invalid transitions" do
    @execution.mark_running!

    assert_raises(QuestExecution::InvalidTransition) { @execution.mark_preparing! }
  end

  test "finishing is idempotent" do
    assert @execution.succeed!
    assert_not @execution.fail!(error_kind: "agent_error")
    assert @execution.reload.succeeded?
  end

  test "rejects unknown error kinds" do
    @execution.error_kind = "mystery"

    assert_not @execution.valid?
  end

  test "instruction must belong to the same quest" do
    other = start_quest
    execution = @quest.executions.build(instruction: other.instructions.first)

    assert_not execution.valid?
  end
end
