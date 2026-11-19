require "test_helper"

class AgentMemoryTest < ActiveSupport::TestCase
  test "upserts, updates, and deletes memories per scope" do
    mem = AgentMemory.apply_event!(
      scope_type: "user",
      scope_key: "slack:U12345",
      payload: { "action" => "upsert", "key" => "display_name", "category" => "profile", "content" => "名前は hamajyotan" },
      quest_public_id: "qst_1"
    )
    assert_equal "profile", mem.category
    assert_equal "名前は hamajyotan", mem.content

    updated = AgentMemory.apply_event!(
      scope_type: "user",
      scope_key: "slack:U12345",
      payload: { "action" => "upsert", "key" => "display_name", "category" => "profile", "content" => "呼び名ははまじょたん" },
      quest_public_id: "qst_2"
    )
    assert_equal mem.id, updated.id
    assert_equal "呼び名ははまじょたん", updated.content

    payload = AgentMemory.prompt_payload_for(scope_type: "user", scope_key: "slack:U12345")
    assert_equal "user:slack:U12345", payload["scope"]
    assert_equal 1, payload["items"].size

    AgentMemory.apply_event!(
      scope_type: "user",
      scope_key: "slack:U12345",
      payload: { "action" => "delete", "key" => "display_name" }
    )
    assert_nil AgentMemory.prompt_payload_for(scope_type: "user", scope_key: "slack:U12345")
  end

  test "normalizes unknown categories to context and trims excess entries" do
    (AgentMemory::MAX_MEMORIES_PER_SCOPE + 3).times do |i|
      AgentMemory.apply_event!(
        scope_type: "user",
        scope_key: "slack:U99999",
        payload: { "key" => "topic_#{i}", "category" => "unknown_cat", "content" => "Topic #{i}" }
      )
    end

    entries = AgentMemory.for_scope("user", "slack:U99999")
    assert_equal AgentMemory::MAX_MEMORIES_PER_SCOPE, entries.count
    assert entries.all? { |m| m.category == "context" }
  end
end
