# A Quest is one piece of work managed by omochi.
#
# It is NOT a wrapper of a Slack thread or a GitHub issue: those are attached as
# ExternalResources. Instructions are queued per Quest and processed strictly one
# at a time, each by a new QuestExecution (see docs/execution.md).
class Quest < ApplicationRecord
  include InstructionQueue

  PUBLIC_ID_PREFIX = "qst_".freeze
  PUBLIC_ID_FORMAT = /\Aqst_\h{8}-\h{4}-7\h{3}-[89ab]\h{3}-\h{12}\z/

  # Provisional status set. See docs/decisions/0002-provisional-statuses.md.
  enum :status, {
    pending: "pending",
    running: "running",
    completed: "completed",
    failed: "failed",
    cancelled: "cancelled"
  }, validate: true

  has_many :external_resources, dependent: :destroy
  has_many :instructions, -> { order(:sequence) }, class_name: "QuestInstruction", dependent: :destroy
  has_many :executions, -> { order(:id) }, class_name: "QuestExecution", dependent: :destroy

  validates :public_id, presence: true, uniqueness: true, format: { with: PUBLIC_ID_FORMAT }
  validates :title, presence: true, length: { maximum: 200 }

  before_validation :assign_public_id, on: :create

  attr_readonly :public_id

  scope :recent, -> { order(updated_at: :desc, id: :desc) }

  def self.generate_public_id
    "#{PUBLIC_ID_PREFIX}#{SecureRandom.uuid_v7}"
  end

  def self.find_by_public_id!(public_id)
    find_by!(public_id: public_id)
  end

  def to_param
    public_id
  end

  def active_execution
    executions.active.first
  end

  # Broadcasts live updates to the Quest detail page (`turbo_stream_from @quest`)
  # and the Quests index table (`turbo_stream_from :quests`).
  def broadcast_dashboard_updates
    reload
    Turbo::StreamsChannel.broadcast_replace_to(
      self,
      target: ActionView::RecordIdentifier.dom_id(self, :detail),
      partial: "quests/detail",
      locals: { quest: self }
    )
    Turbo::StreamsChannel.broadcast_replace_to(
      :quests,
      target: ActionView::RecordIdentifier.dom_id(self),
      partial: "quests/quest_row",
      locals: { quest: self }
    )
  rescue StandardError => e
    Rails.error.report(e, context: { quest: public_id })
  end

  private
    def assign_public_id
      self.public_id ||= self.class.generate_public_id
    end
end
