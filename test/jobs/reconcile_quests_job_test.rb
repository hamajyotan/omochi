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
end
