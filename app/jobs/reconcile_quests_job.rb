# Periodic maintenance and recovery job:
# 1. Marks active Executions whose worker heartbeat has expired as failed with
#    `error_kind: "worker_lost"` so the Quest is not stuck forever.
# 2. Retries container removal for Executions whose container cleanup is still
#    `pending` or `failed`.
# 3. Re-enqueues Quests that have queued instructions but no active Execution
#    (safety net for lost enqueues between the primary DB and queue DB).
class ReconcileQuestsJob < ApplicationJob
  queue_as :default

  def perform
    recover_stale_executions!
    retry_pending_cleanups!
    enqueue_stranded_quests!
  end

  private
    def recover_stale_executions!
      timeout = Omochi::Settings.dig(:docker, :heartbeat_timeout_seconds).to_i
      timeout = 90 if timeout <= 0
      cutoff = timeout.seconds.ago

      QuestExecution.stale_active(cutoff).find_each do |execution|
        execution.fail!(
          error_kind: "worker_lost",
          error_message: "Worker heartbeat expired (last seen before #{cutoff.iso8601})"
        )
      end
    end

    def retry_pending_cleanups!
      active_ids = QuestExecution.active.select(:id)
      docker_client = QuestExecution::DockerRunner.docker_client_factory.call

      QuestExecution.needs_cleanup.where.not(id: active_ids).find_each do |execution|
        docker_client.remove_container(execution.container_id)
        execution.mark_cleaned_up!
      rescue StandardError => e
        Rails.error.report(e, context: { execution_id: execution.id, container_id: execution.container_id })
        execution.mark_cleanup_failed!
      end
    end

    def enqueue_stranded_quests!
      Quest.where(id: QuestInstruction.queued.select(:quest_id))
        .where.not(id: QuestExecution.active.select(:quest_id))
        .find_each { |quest| QuestProcessingJob.perform_later(quest) }
    end
end
