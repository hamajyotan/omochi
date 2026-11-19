class CreateAgentMemories < ActiveRecord::Migration[8.1]
  def change
    create_table :agent_memories do |t|
      t.string :scope_type, null: false
      t.string :scope_key, null: false
      t.string :category, null: false, default: "context"
      t.string :memory_key, null: false
      t.text :content, null: false
      t.string :source_quest_public_id
      t.datetime :last_referenced_at
      t.timestamps
    end

    add_index :agent_memories, %i[scope_type scope_key memory_key], unique: true,
      name: "index_agent_memories_on_scope_and_key"
    add_index :agent_memories, %i[scope_type scope_key updated_at],
      name: "index_agent_memories_on_scope_and_updated_at"
  end
end
