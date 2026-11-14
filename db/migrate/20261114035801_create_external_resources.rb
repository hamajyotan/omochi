class CreateExternalResources < ActiveRecord::Migration[8.1]
  def change
    create_table :external_resources do |t|
      t.references :quest, null: false, foreign_key: true
      t.string :platform, null: false       # e.g. "slack", "github"
      t.string :resource_type, null: false  # e.g. "thread", "issue", "pull_request"
      t.string :scope_key, null: false      # e.g. Slack team/channel, GitHub owner/repo
      t.string :external_id, null: false    # ID inside the scope (e.g. thread_ts, issue number)
      t.string :url
      t.timestamps
    end
    add_index :external_resources, %i[platform resource_type scope_key external_id],
      unique: true, name: "index_external_resources_on_identity"
  end
end
