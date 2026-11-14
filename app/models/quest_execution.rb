# One run of an agent processing a QuestInstruction. Executions are never
# overwritten; re-running work always creates a new Execution.
class QuestExecution < ApplicationRecord
  class InvalidTransition < StandardError; end

  ACTIVE_STATUSES = %w[queued preparing running].freeze
  FINISHED_STATUSES = %w[succeeded failed cancelled].freeze

  # Failure classes we must be able to tell apart (docs/execution.md §6).
  ERROR_KINDS = %w[
    agent_error
    container_error
    worker_lost
    timeout
    cancelled_by_user
    internal_error
  ].freeze

  enum :status, {
    queued: "queued",
    preparing: "preparing",
    running: "running",
    succeeded: "succeeded",
    failed: "failed",
    cancelled: "cancelled"
  }, validate: true

  belongs_to :quest
  belongs_to :instruction, class_name: "QuestInstruction", foreign_key: :quest_instruction_id, inverse_of: :executions

  validates :error_kind, inclusion: { in: ERROR_KINDS }, allow_nil: true
  validate :instruction_belongs_to_quest

  scope :active, -> { where(status: ACTIVE_STATUSES) }

  # The runner that actually performs the work. Phase 1 uses a host-side
  # placeholder; Phase 2 replaces it with the Docker based Mock Agent runner.
  class_attribute :runner, default: "QuestExecution::PlaceholderRunner"

  def self.build_runner
    runner.constantize.new
  end

  def mark_preparing!
    transition!(from: %w[queued], to: :preparing)
  end

  def mark_running!
    transition!(from: %w[queued preparing], to: :running, started_at: Time.current)
  end

  def succeed!(result_summary: nil)
    finish!(status: :succeeded, instruction_status: :processed, result_summary:)
  end

  def fail!(error_kind:, error_message: nil)
    finish!(status: :failed, instruction_status: :failed, error_kind:, error_message: error_message&.truncate(10_000))
  end

  def active?
    ACTIVE_STATUSES.include?(status)
  end

  def finished?
    FINISHED_STATUSES.include?(status)
  end

  def duration
    return unless started_at && finished_at

    finished_at - started_at
  end

  private
    def transition!(from:, to:, **attributes)
      transaction do
        reload
        raise InvalidTransition, "#{status} -> #{to}" unless from.include?(status)

        update!(status: to, **attributes)
      end
    end

    # Finishing is idempotent: returns false if the Execution already finished.
    def finish!(status:, instruction_status:, **attributes)
      finished = transaction do
        reload
        next false unless active?

        update!(status:, finished_at: Time.current, **attributes)
        instruction.update!(status: instruction_status)
        quest.settle_after_execution!(self)
        true
      end
      quest.enqueue_processing if finished && quest.queued_instructions?
      finished
    end

    def instruction_belongs_to_quest
      return if instruction.nil? || instruction.quest_id == quest_id

      errors.add(:instruction, "must belong to the same quest")
    end
end
