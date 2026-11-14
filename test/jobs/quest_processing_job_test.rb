require "test_helper"

class QuestProcessingJobTest < ActiveJob::TestCase
  class FailingRunner
    def run(execution)
      execution.mark_running!
      raise "container exploded"
    end
  end

  test "processes all queued instructions sequentially with the placeholder runner" do
    quest = start_quest(body: "first")
    quest.receive_instruction!(body: "second", source_platform: "dashboard")

    perform_enqueued_jobs

    assert quest.reload.completed?
    assert_equal 2, quest.executions.count
    assert quest.executions.all?(&:succeeded?)
    assert_equal QuestExecution::PlaceholderRunner::SUMMARY, quest.executions.first.result_summary
    assert_equal %w[processed processed], quest.instructions.pluck(:status)
  end

  test "running the job again does not create duplicate executions" do
    quest = start_quest
    perform_enqueued_jobs

    assert_no_difference -> { QuestExecution.count } do
      QuestProcessingJob.perform_now(quest)
    end
  end

  test "an unexpected runner error is recorded as an internal_error failure" do
    QuestExecution.runner = FailingRunner.name
    quest = start_quest
    perform_enqueued_jobs

    execution = quest.executions.sole
    assert execution.failed?
    assert_equal "internal_error", execution.error_kind
    assert_includes execution.error_message, "container exploded"
    assert quest.reload.failed?
  ensure
    QuestExecution.runner = "QuestExecution::PlaceholderRunner"
  end
end
