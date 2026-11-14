class CreateQuests < ActiveRecord::Migration[8.1]
  def change
    create_table :quests do |t|
      # Externally visible Quest ID ("qst_" + UUIDv7). Independent of the internal PK
      # and of any external platform ID. See docs/decisions/0001-quest-id-format.md.
      t.string :public_id, null: false
      t.string :title, null: false
      t.string :status, null: false, default: "pending"
      t.timestamps
    end
    add_index :quests, :public_id, unique: true
    add_index :quests, :status
  end
end
