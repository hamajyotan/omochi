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

  CLEANUP_STATUSES = %w[not_needed pending completed failed].freeze

  enum :status, {
    queued: "queued",
    preparing: "preparing",
    running: "running",
    succeeded: "succeeded",
    failed: "failed",
    cancelled: "cancelled"
  }, validate: true

  enum :cleanup_status, {
    not_needed: "not_needed",
    pending: "pending",
    completed: "completed",
    failed: "failed"
  }, prefix: :cleanup, validate: true

  belongs_to :quest
  belongs_to :instruction, class_name: "QuestInstruction", foreign_key: :quest_instruction_id, inverse_of: :executions
  has_many :events, -> { order(:sequence) }, class_name: "QuestExecutionEvent",
    foreign_key: :quest_execution_id, inverse_of: :execution, dependent: :destroy

  validates :error_kind, inclusion: { in: ERROR_KINDS }, allow_nil: true
  validate :instruction_belongs_to_quest

  scope :active, -> { where(status: ACTIVE_STATUSES) }
  scope :needs_cleanup, -> { where(cleanup_status: %w[pending failed]).where.not(container_id: nil) }
  scope :stale_active, ->(cutoff) { active.where("COALESCE(heartbeat_at, started_at, updated_at) < ?", cutoff) }

  # The runner that actually performs the work. Defaults to the Docker based
  # runner in development/production; tests can swap this to a fake or
  # placeholder runner.
  class_attribute :runner, default: "QuestExecution::DockerRunner"

  def self.build_runner
    runner.constantize.new
  end

  def mark_preparing!(workspace_path: nil)
    now = Time.current
    attrs = { heartbeat_at: now }
    attrs[:workspace_path] = workspace_path if workspace_path
    transition!(from: %w[queued], to: :preparing, **attrs)
    quest.broadcast_dashboard_updates
  end

  def mark_running!(container_id: nil)
    now = Time.current
    attrs = { started_at: now, heartbeat_at: now }
    if container_id.present?
      attrs[:container_id] = container_id
      attrs[:cleanup_status] = "pending"
    end
    transition!(from: %w[queued preparing], to: :running, **attrs)
    quest.broadcast_dashboard_updates
  end

  def touch_heartbeat!(at: Time.current)
    update_columns(heartbeat_at: at, updated_at: at)
  end

  def record_event!(event_type:, message: nil, payload: {}, occurred_at: Time.current)
    event = transaction do
      next_seq = (events.maximum(:sequence) || 0) + 1
      created = events.create!(
        sequence: next_seq,
        event_type: event_type,
        message: message,
        payload: payload || {},
        occurred_at: occurred_at
      )
      touch_heartbeat!(at: occurred_at)
      created
    end
    quest.broadcast_dashboard_updates
    event
  end

  def record_output_line!(raw_line, stream: "stdout")
    sanitized_line = Omochi::SecretRedactor.redact(raw_line)
    attrs = QuestExecutionEvent.parse_line(sanitized_line, stream: stream)
    record_event!(**attrs)
  end

  def mark_cleaned_up!
    update!(cleanup_status: :completed)
    quest.broadcast_dashboard_updates
  end

  def mark_cleanup_failed!
    update!(cleanup_status: :failed)
    quest.broadcast_dashboard_updates
  end

  def succeed!(result_summary: nil, exit_code: nil)
    finish!(
      status: :succeeded,
      instruction_status: :processed,
      result_summary: Omochi::SecretRedactor.redact(result_summary),
      exit_code:
    )
  end

  def fail!(error_kind:, error_message: nil, exit_code: nil)
    finish!(
      status: :failed,
      instruction_status: :failed,
      error_kind:,
      error_message: Omochi::SecretRedactor.redact(error_message)&.truncate(10_000),
      exit_code:
    )
  end

  def cancel_in_transaction!(reason: "Cancelled by user")
    return false unless active?

    update!(
      status: :cancelled,
      finished_at: Time.current,
      error_kind: "cancelled_by_user",
      error_message: reason
    )
    instruction.update!(status: :cancelled)
    notify_slack!(
      "🛑 Instruction ##{instruction.sequence} cancelled for `#{quest.public_id}`.",
      remove_reaction_ts: instruction.slack_message_ts
    )
    true
  end

  def stop_and_cleanup_container!
    return if container_id.blank?

    docker_client = QuestExecution::DockerRunner.docker_client_factory.call
    docker_client.stop_container(container_id)
    docker_client.remove_container(container_id)
    mark_cleaned_up!
  rescue StandardError => e
    Rails.error.report(e, context: { execution_id: id, container_id: container_id })
    mark_cleanup_failed!
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

        update!(status:, finished_at: Time.current, **attributes.compact)
        instruction.update!(status: instruction_status)
        quest.settle_after_execution!(self)
        true
      end
      if finished
        notify_slack_finished!
        quest.broadcast_dashboard_updates
        quest.enqueue_processing if quest.queued_instructions?
      end
      finished
    end

    def notify_slack_finished!
      text =
        if succeeded?
          result_summary.presence || "Completed."
        elsif failed?
          reason = error_message.presence || error_kind || "unknown error"
          "⚠️ Instruction ##{instruction.sequence} failed for `#{quest.public_id}` (#{error_kind}): #{reason}"
        end
      notify_slack!(text, remove_reaction_ts: instruction.slack_message_ts) if text
      notify_github_finished!
    end

    def notify_github_finished!
      resource = instruction.external_resource
      return unless resource&.platform == "github"

      body =
        if succeeded?
          summary = result_summary.presence || "Review completed."
          "### 🍡 omochi review result (Instruction ##{instruction.sequence})

#{summary}"
        elsif failed?
          reason = error_message.presence || error_kind || "unknown error"
          "### ⚠️ omochi execution failed (Instruction ##{instruction.sequence})

**Error (#{error_kind}):** #{reason}"
        end

      return unless body

      GitHubNotificationJob.perform_later(resource, body)
    rescue StandardError => e
      Rails.error.report(e, context: { execution_id: id })
    end

    def notify_slack!(text, remove_reaction_ts: nil)
      resource = instruction.external_resource
      return unless resource&.platform == "slack" && resource.resource_type == "thread"

      SlackNotificationJob.perform_later(resource, text, remove_reaction_ts: remove_reaction_ts)
    rescue StandardError => e
      Rails.error.report(e, context: { execution_id: id })
    end

    def instruction_belongs_to_quest
      return if instruction.nil? || instruction.quest_id == quest_id

      errors.add(:instruction, "must belong to the same quest")
    end
end
