class CreateQuestExecutions < ActiveRecord::Migration[8.1]
  def change
    create_table :quest_executions do |t|
      t.references :quest, null: false, foreign_key: true
      t.references :quest_instruction, null: false, foreign_key: true
      t.string :status, null: false, default: "queued"
      t.datetime :started_at
      t.datetime :finished_at
      # Failure classification (agent_error, container_error, worker_lost, timeout, ...).
      t.string :error_kind
      t.text :error_message
      t.text :result_summary
      t.timestamps
    end
    # At most one active Execution per Quest, enforced by the database.
    add_index :quest_executions, :quest_id, unique: true,
      where: "status IN ('queued', 'preparing', 'running')",
      name: "index_quest_executions_on_active_quest"
  end
end
