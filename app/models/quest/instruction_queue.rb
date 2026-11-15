# Per-Quest instruction queue (docs/execution.md).
#
# Guarantees:
# - Instructions are persisted before any processing starts, in acceptance order.
# - Duplicate external events (same source_platform + source_event_id) are
#   accepted only once.
# - At most one active QuestExecution per Quest (also enforced by a partial
#   unique index), and claiming the next instruction + creating the Execution
#   happen in one short transaction.
#
# SQLite transactions are IMMEDIATE in Rails 8, so the write lock is taken at
# BEGIN; keep every transaction here short and never run agents inside them.
module Quest::InstructionQueue
  extend ActiveSupport::Concern

  class InstructionRejected < StandardError; end

  # Completed / failed Quests are automatically reopened by a new instruction.
  # Cancelled Quests require an explicit `reopen!` or `retry!` from the Dashboard
  # (docs/decisions/0007-quest-cancel-reopen-and-retry.md).
  REOPENABLE_STATUSES = %w[completed failed].freeze

  class_methods do
    # Creates a new Quest together with its first instruction.
    # Returns the QuestInstruction (use #quest to get the Quest). If the source
    # event was already accepted, returns the previously accepted instruction.
    def start!(title:, body:, source_platform:, source_event_id: nil, external_resource: nil, metadata: {}, enqueue: true)
      instruction = QuestInstruction.find_duplicate(source_platform:, source_event_id:)
      return instruction if instruction

      instruction = transaction do
        quest = create!(title:)
        resource = quest.external_resources.create!(external_resource) if external_resource
        quest.send(:append_instruction!, body:, source_platform:, source_event_id:, external_resource: resource, metadata:)
      end
      instruction.quest.broadcast_dashboard_updates
      instruction.quest.enqueue_processing if enqueue
      instruction
    rescue ActiveRecord::RecordNotUnique
      QuestInstruction.find_duplicate(source_platform:, source_event_id:) || raise
    end
  end

  # Accepts a follow-up instruction for this Quest.
  # Returns the QuestInstruction; duplicates return the earlier instruction.
  def receive_instruction!(body:, source_platform:, source_event_id: nil, external_resource: nil, metadata: {}, enqueue: true)
    instruction = QuestInstruction.find_duplicate(source_platform:, source_event_id:)
    return instruction if instruction

    instruction = transaction do
      reload
      raise InstructionRejected, "Quest #{public_id} is #{status}" if cancelled?

      update!(status: :pending) if REOPENABLE_STATUSES.include?(status)
      append_instruction!(body:, source_platform:, source_event_id:, external_resource:, metadata:)
    end
    broadcast_dashboard_updates
    enqueue_processing if enqueue
    instruction
  rescue ActiveRecord::RecordNotUnique
    QuestInstruction.find_duplicate(source_platform:, source_event_id:) || raise
  end

  # Atomically claims the oldest queued instruction and creates its Execution.
  # Returns the new QuestExecution, or nil when there is nothing to do or another
  # Execution is already active. Safe to call repeatedly / concurrently.
  def claim_next_instruction!
    execution = transaction do
      next nil if executions.active.exists?

      instruction = instructions.queued.in_queue_order.first
      next nil unless instruction

      instruction.update!(status: :processing)
      update!(status: :running)
      executions.create!(instruction:, status: :queued)
    end
    broadcast_dashboard_updates if execution
    execution
  rescue ActiveRecord::RecordNotUnique
    nil
  end

  # Cancels the Quest, any active Execution (including stopping its container),
  # and any queued/processing instructions.
  def cancel!
    active_exec = nil
    transaction do
      reload
      active_exec = executions.active.first
      active_exec&.cancel_in_transaction!(reason: "Cancelled by user")
      instructions.where(status: %w[queued processing]).find_each do |inst|
        inst.update!(status: :cancelled)
      end
      update!(status: :cancelled)
    end

    active_exec&.stop_and_cleanup_container!
    broadcast_dashboard_updates
    true
  end

  # Explicitly reopens a cancelled (or failed/completed) Quest from the Dashboard.
  def reopen!
    transaction do
      reload
      update!(status: :pending) unless running?
    end
    broadcast_dashboard_updates
    enqueue_processing if queued_instructions?
    true
  end

  # Called inside the Execution's finishing transaction.
  def settle_after_execution!(execution)
    next_status =
      if instructions.queued.exists?
        :pending
      elsif execution.succeeded?
        :completed
      elsif execution.cancelled?
        :cancelled
      else
        :failed
      end
    update!(status: next_status)
  end

  def queued_instructions?
    instructions.queued.exists?
  end

  def cancellable?
    pending? || running?
  end

  # Enqueue outside of any transaction: the queue lives in a separate database.
  # If enqueueing is lost, ReconcileQuestsJob picks the Quest up again.
  def enqueue_processing
    QuestProcessingJob.perform_later(self)
  end

  private
    def append_instruction!(body:, source_platform:, source_event_id:, external_resource:, metadata: {})
      instructions.create!(
        sequence: (instructions.maximum(:sequence) || 0) + 1,
        body:,
        source_platform:,
        source_event_id:,
        external_resource:,
        metadata: metadata || {},
        received_at: Time.current
      )
    end
end
