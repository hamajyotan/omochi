# Persistent self-learned context about users or scopes stored outside source control.
class AgentMemory < ApplicationRecord
  CATEGORIES = %w[profile preference follow_up context].freeze
  MAX_MEMORIES_PER_SCOPE = 30
  MAX_CONTENT_LENGTH = 500
  MAX_KEY_LENGTH = 100

  validates :scope_type, presence: true
  validates :scope_key, presence: true
  validates :category, inclusion: { in: CATEGORIES }
  validates :memory_key, presence: true, length: { maximum: MAX_KEY_LENGTH },
    uniqueness: { scope: %i[scope_type scope_key] }
  validates :content, presence: true, length: { maximum: MAX_CONTENT_LENGTH }

  scope :for_scope, ->(scope_type, scope_key) { where(scope_type:, scope_key:) }
  scope :recent_first, -> { order(updated_at: :desc, id: :desc) }

  # Applies a structured `memory` event emitted by an Agent Container.
  def self.apply_event!(scope_type:, scope_key:, payload:, quest_public_id: nil)
    return if scope_type.blank? || scope_key.blank? || !payload.is_a?(Hash)

    key = payload["key"].to_s.strip.truncate(MAX_KEY_LENGTH, omission: "")
    return if key.blank?

    action = payload["action"].to_s.strip.downcase
    action = "upsert" if action.blank?

    if action == "delete"
      for_scope(scope_type, scope_key).where(memory_key: key).delete_all
      return nil
    end

    content = payload["content"].to_s.strip.truncate(MAX_CONTENT_LENGTH)
    return nil if content.blank?

    category = payload["category"].to_s.strip.downcase
    category = "context" unless CATEGORIES.include?(category)

    memory = find_or_initialize_by(scope_type:, scope_key:, memory_key: key)
    memory.update!(
      category: category,
      content: content,
      source_quest_public_id: quest_public_id,
      last_referenced_at: Time.current
    )

    trim_excess_memories!(scope_type:, scope_key:)
    memory
  end

  def self.prompt_payload_for(scope_type:, scope_key:, limit: 20)
    return nil if scope_type.blank? || scope_key.blank?

    items = for_scope(scope_type, scope_key).recent_first.limit(limit).map do |memory|
      {
        "key" => memory.memory_key,
        "category" => memory.category,
        "content" => memory.content,
        "updated_at" => memory.updated_at.iso8601
      }
    end
    return nil if items.empty?

    {
      "scope" => "#{scope_type}:#{scope_key}",
      "items" => items
    }
  end

  def self.trim_excess_memories!(scope_type:, scope_key:)
    scope = for_scope(scope_type, scope_key)
    excess = scope.count - MAX_MEMORIES_PER_SCOPE
    return if excess <= 0

    # Prefer keeping profile memories when trimming oldest entries.
    ids_to_delete = scope
      .order(Arel.sql("CASE WHEN category = 'profile' THEN 1 ELSE 0 END ASC, updated_at ASC, id ASC"))
      .limit(excess)
      .pluck(:id)
    where(id: ids_to_delete).delete_all if ids_to_delete.any?
  end
  private_class_method :trim_excess_memories!
end
