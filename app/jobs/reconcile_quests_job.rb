# Safety net for lost enqueues: the queue lives in a separate database, so
# "instruction persisted" and "job enqueued" are not atomic. Finds Quests that
# have queued instructions but no active Execution and schedules them again.
#
# Detecting Executions abandoned by a crashed worker requires heartbeats and is
# handled together with the Docker runner in Phase 2.
class ReconcileQuestsJob < ApplicationJob
  queue_as :default

  def perform
    Quest.where(id: QuestInstruction.queued.select(:quest_id))
      .where.not(id: QuestExecution.active.select(:quest_id))
      .find_each { |quest| QuestProcessingJob.perform_later(quest) }
  end
end
