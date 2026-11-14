require "test_helper"

class QuestInstructionQueueTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "start! persists the quest and its first instruction, then enqueues processing" do
    instruction = nil

    assert_enqueued_with(job: QuestProcessingJob) do
      instruction = Quest.start!(title: "Fix bug", body: "Please fix", source_platform: "dashboard")
    end

    quest = instruction.quest
    assert quest.persisted?
    assert quest.pending?
    assert_equal 1, instruction.sequence
    assert instruction.queued?
    assert_equal "Please fix", instruction.body
    assert_not_nil instruction.received_at
  end

  test "start! can attach an external resource to the quest and instruction" do
    instruction = Quest.start!(
      title: "From Slack", body: "hi", source_platform: "slack", source_event_id: "Ev001",
      external_resource: { platform: "slack", resource_type: "thread", scope_key: "T1/C1", external_id: "111.222" }
    )

    resource = instruction.quest.external_resources.sole
    assert_equal resource, instruction.external_resource
  end

  test "start! with an already accepted source event returns the existing instruction" do
    first = Quest.start!(title: "a", body: "a", source_platform: "slack", source_event_id: "Ev1")

    assert_no_difference -> { Quest.count } do
      second = Quest.start!(title: "a", body: "a", source_platform: "slack", source_event_id: "Ev1")
      assert_equal first, second
    end
  end

  test "start! rolls back everything when the instruction is invalid" do
    assert_no_difference [ -> { Quest.count }, -> { QuestInstruction.count } ] do
      assert_raises(ActiveRecord::RecordInvalid) do
        Quest.start!(title: "a", body: "", source_platform: "dashboard")
      end
    end
  end

  test "instructions get increasing sequence numbers in acceptance order" do
    quest = start_quest
    second = quest.receive_instruction!(body: "second", source_platform: "dashboard")
    third = quest.receive_instruction!(body: "third", source_platform: "dashboard")

    assert_equal [ 1, 2, 3 ], quest.instructions.pluck(:sequence)
    assert_equal [ 2, 3 ], [ second.sequence, third.sequence ]
  end

  test "duplicate source events are accepted only once" do
    quest = start_quest
    first = quest.receive_instruction!(body: "x", source_platform: "slack", source_event_id: "Ev9")

    assert_no_difference -> { QuestInstruction.count } do
      assert_equal first, quest.receive_instruction!(body: "x", source_platform: "slack", source_event_id: "Ev9")
    end
  end

  test "the same event id on different platforms is not a duplicate" do
    quest = start_quest
    quest.receive_instruction!(body: "x", source_platform: "slack", source_event_id: "1")

    assert_difference -> { QuestInstruction.count } do
      quest.receive_instruction!(body: "x", source_platform: "github", source_event_id: "1")
    end
  end

  test "instruction body is immutable once accepted" do
    instruction = start_quest.instructions.first

    assert_raises(ActiveRecord::ActiveRecordError) { instruction.update!(body: "changed") }
  end

  test "claim creates an execution for the oldest queued instruction" do
    quest = start_quest(body: "first")
    quest.receive_instruction!(body: "second", source_platform: "dashboard")

    execution = quest.claim_next_instruction!

    assert execution.queued?
    assert_equal "first", execution.instruction.body
    assert execution.instruction.processing?
    assert quest.reload.running?
  end

  test "claim returns nil while another execution is active" do
    quest = start_quest
    quest.receive_instruction!(body: "second", source_platform: "dashboard")
    quest.claim_next_instruction!

    assert_no_difference -> { QuestExecution.count } do
      assert_nil quest.claim_next_instruction!
    end
  end

  test "claim returns nil when nothing is queued" do
    quest = Quest.create!(title: "empty")

    assert_nil quest.claim_next_instruction!
  end

  test "database allows at most one active execution per quest" do
    quest = start_quest
    quest.receive_instruction!(body: "second", source_platform: "dashboard")
    first, second = quest.instructions.to_a
    quest.executions.create!(instruction: first, status: :running)

    assert_raises(ActiveRecord::RecordNotUnique) do
      quest.executions.create!(instruction: second, status: :queued)
    end
  end

  test "claim treats a unique index conflict as 'already running'" do
    quest = start_quest
    quest.define_singleton_method(:executions) { raise ActiveRecord::RecordNotUnique, "race" }

    assert_nil quest.claim_next_instruction!
  end

  test "finishing an execution processes instructions one by one in order" do
    quest = start_quest(body: "first")
    quest.receive_instruction!(body: "second", source_platform: "dashboard")

    first = quest.claim_next_instruction!
    first.mark_running!
    assert_enqueued_with(job: QuestProcessingJob) { first.succeed!(result_summary: "ok") }
    assert quest.reload.pending?, "quest waits for the next instruction"

    second = quest.claim_next_instruction!
    assert_equal "second", second.instruction.body
    second.mark_running!
    second.succeed!

    assert quest.reload.completed?
    assert_equal %w[processed processed], quest.instructions.pluck(:status)
  end

  test "a failed execution marks the instruction and quest failed" do
    quest = start_quest
    execution = quest.claim_next_instruction!
    execution.fail!(error_kind: "agent_error", error_message: "boom")

    assert quest.reload.failed?
    assert execution.instruction.reload.failed?
    assert_equal "agent_error", execution.reload.error_kind
  end

  test "a new instruction reopens a completed quest with the same id and keeps history" do
    quest = start_quest
    public_id = quest.public_id
    quest.claim_next_instruction!.succeed!
    assert quest.reload.completed?

    quest.receive_instruction!(body: "again", source_platform: "dashboard")
    assert quest.reload.pending?

    execution = quest.claim_next_instruction!
    assert_equal public_id, quest.reload.public_id
    assert_equal 2, quest.executions.count
    assert_equal "again", execution.instruction.body
  end

  test "a new instruction reopens a failed quest" do
    quest = start_quest
    quest.claim_next_instruction!.fail!(error_kind: "timeout")

    quest.receive_instruction!(body: "retry please", source_platform: "dashboard")

    assert quest.reload.pending?
  end

  test "a cancelled quest rejects new instructions (provisional)" do
    quest = start_quest
    quest.update!(status: :cancelled)

    assert_raises(Quest::InstructionQueue::InstructionRejected) do
      quest.receive_instruction!(body: "x", source_platform: "dashboard")
    end
  end

  test "instructions received during an execution stay queued and do not change the running one" do
    quest = start_quest(body: "original")
    execution = quest.claim_next_instruction!
    execution.mark_running!

    quest.receive_instruction!(body: "follow-up", source_platform: "dashboard")

    assert quest.reload.running?
    assert_equal "original", execution.reload.instruction.body
    assert_equal %w[processing queued], quest.instructions.pluck(:status)
  end
end
