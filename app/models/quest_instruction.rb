# A request or follow-up instruction for a Quest, persisted in the order omochi
# accepted it. The body is immutable once accepted.
class QuestInstruction < ApplicationRecord
  SOURCE_PLATFORMS = %w[dashboard slack github].freeze
  MAX_BODY_LENGTH = 10_000

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

  private
    def external_resource_belongs_to_quest
      return if external_resource.nil? || external_resource.quest_id == quest_id

      errors.add(:external_resource, "must belong to the same quest")
    end
end
