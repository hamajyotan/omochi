class AddMetadataToQuestInstructions < ActiveRecord::Migration[8.1]
  def change
    add_column :quest_instructions, :metadata, :json, default: {}, null: false
  end
end
