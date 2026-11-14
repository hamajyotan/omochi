class CreateQuestInstructions < ActiveRecord::Migration[8.1]
  def change
    create_table :quest_instructions do |t|
      t.references :quest, null: false, foreign_key: true
      # Order in which omochi accepted and persisted the instruction (per Quest).
      t.integer :sequence, null: false
      t.text :body, null: false
      t.string :status, null: false, default: "queued"
      # Where the instruction came from ("dashboard", "slack", ...).
      t.string :source_platform, null: false
      # External event ID used for de-duplication (e.g. Slack event_id). Nullable.
      t.string :source_event_id
      t.references :external_resource, foreign_key: true
      t.datetime :received_at, null: false
      t.timestamps
    end
    add_index :quest_instructions, %i[quest_id sequence], unique: true
    add_index :quest_instructions, %i[quest_id status sequence]
    add_index :quest_instructions, %i[source_platform source_event_id], unique: true,
      where: "source_event_id IS NOT NULL", name: "index_quest_instructions_on_source_event"
  end
end
