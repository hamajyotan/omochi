class CreateQuestExecutionEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :quest_execution_events do |t|
      t.references :quest_execution, null: false, foreign_key: true
      t.integer :sequence, null: false
      t.string :event_type, null: false
      t.text :message
      t.json :payload, null: false, default: {}
      t.datetime :occurred_at, null: false
      t.timestamps
    end

    add_index :quest_execution_events, %i[quest_execution_id sequence], unique: true,
      name: "index_quest_execution_events_on_execution_and_sequence"
  end
end
