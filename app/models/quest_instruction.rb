# A request or follow-up instruction for a Quest, persisted in the order omochi
# accepted it. The body is immutable once accepted.
class QuestInstruction < ApplicationRecord
  class CannotRetry < StandardError; end

  SOURCE_PLATFORMS = %w[dashboard slack github].freeze
  MAX_BODY_LENGTH = 10_000
  RETRYABLE_STATUSES = %w[failed cancelled].freeze

  enum :status, {
    queued: "queued",
    processing: "processing",
    processed: "processed",
    failed: "failed",
    cancelled: "cancelled"
  }, validate: true

  belongs_to :quest
  belongs_to :external_resource, optional: true
  has_many :executions, class_name: "QuestExecution", dependent: :destroy

  validates :body, presence: true, length: { maximum: MAX_BODY_LENGTH }
  validates :source_platform, inclusion: { in: SOURCE_PLATFORMS }
  validates :sequence, presence: true, uniqueness: { scope: :quest_id }
  validates :received_at, presence: true
  validate :external_resource_belongs_to_quest

  attr_readonly :body, :sequence, :quest_id, :source_platform, :source_event_id

  scope :in_queue_order, -> { order(:sequence) }

  def self.find_duplicate(source_platform:, source_event_id:)
    return if source_event_id.blank?

    find_by(source_platform:, source_event_id:)
  end

  def retryable?
    RETRYABLE_STATUSES.include?(status)
  end

  def slack_message_ts
    (metadata.is_a?(Hash) && metadata["slack_message_ts"].presence) || external_resource&.external_id
  end

  def memory_scope
    return nil unless metadata.is_a?(Hash)

    if source_platform == "slack" && metadata["slack_user_id"].present?
      [ "user", "slack:#{metadata['slack_user_id']}" ]
    end
  end

  # Re-queues a failed or cancelled instruction so a new QuestExecution will
  # process it while keeping all past QuestExecutions intact.
  def retry!
    transaction do
      reload
      raise CannotRetry, "Instruction ##{sequence} is #{status} and cannot be retried" unless retryable?

      update!(status: :queued)
      quest.reload
      quest.update!(status: :pending) unless quest.running?
    end
    quest.broadcast_dashboard_updates
    quest.enqueue_processing
    self
  end

  private
    def external_resource_belongs_to_quest
      return if external_resource.nil? || external_resource.quest_id == quest_id

      errors.add(:external_resource, "must belong to the same quest")
    end
end
