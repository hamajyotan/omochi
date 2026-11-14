require "test_helper"

class ReconcileQuestsJobTest < ActiveJob::TestCase
  test "re-enqueues quests that have queued instructions but no active execution" do
    stranded = start_quest
    busy = start_quest
    busy.receive_instruction!(body: "second", source_platform: "dashboard")
    busy.claim_next_instruction!
    idle = start_quest
    idle.claim_next_instruction!.succeed!
    clear_enqueued_jobs

    ReconcileQuestsJob.perform_now

    assert_enqueued_jobs 1, only: QuestProcessingJob
    assert_enqueued_with(job: QuestProcessingJob, args: [ stranded ])
  end

  test "marks stale active executions as worker_lost and retries failed container cleanups" do
    quest = start_quest
    stale = quest.claim_next_instruction!
    stale.mark_running!(container_id: "stale_ctr_1")
    stale.update_columns(heartbeat_at: 10.minutes.ago, updated_at: 10.minutes.ago)
    clear_enqueued_jobs

    ReconcileQuestsJob.perform_now

    stale.reload
    assert stale.failed?
    assert_equal "worker_lost", stale.error_kind
    assert_equal "completed", stale.cleanup_status
    assert_includes @fake_docker_client.removed_containers, "stale_ctr_1"
    assert quest.reload.failed?
  end
end
