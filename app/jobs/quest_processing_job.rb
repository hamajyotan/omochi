# Processes the next queued instruction of a Quest.
#
# This job may run more than once for the same Quest (duplicates, retries,
# reconcile). Exclusivity comes from Quest#claim_next_instruction!, not from
# Solid Queue ordering.
class QuestProcessingJob < ApplicationJob
  queue_as :default

  discard_on ActiveJob::DeserializationError

  def perform(quest)
    execution = quest.claim_next_instruction!
    return unless execution

    begin
      QuestExecution.build_runner.run(execution)
    rescue StandardError => error
      Rails.error.report(error, context: { quest: quest.public_id, execution_id: execution.id })
      execution.fail!(error_kind: "internal_error", error_message: "#{error.class}: #{error.message}")
    end
  end
end
