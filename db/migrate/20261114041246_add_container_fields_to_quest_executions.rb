class AddContainerFieldsToQuestExecutions < ActiveRecord::Migration[8.1]
  def change
    add_column :quest_executions, :container_id, :string
    add_column :quest_executions, :workspace_path, :string
    add_column :quest_executions, :exit_code, :integer
    add_column :quest_executions, :heartbeat_at, :datetime
    add_column :quest_executions, :cleanup_status, :string, null: false, default: "not_needed"

    add_index :quest_executions, :cleanup_status
  end
end
