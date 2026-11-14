# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_11_14_035804) do
  create_table "external_resources", force: :cascade do |t|
    t.integer "quest_id", null: false
    t.string "platform", null: false
    t.string "resource_type", null: false
    t.string "scope_key", null: false
    t.string "external_id", null: false
    t.string "url"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["platform", "resource_type", "scope_key", "external_id"], name: "index_external_resources_on_identity", unique: true
    t.index ["quest_id"], name: "index_external_resources_on_quest_id"
  end

  create_table "quest_executions", force: :cascade do |t|
    t.integer "quest_id", null: false
    t.integer "quest_instruction_id", null: false
    t.string "status", default: "queued", null: false
    t.datetime "started_at"
    t.datetime "finished_at"
    t.string "error_kind"
    t.text "error_message"
    t.text "result_summary"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["quest_id"], name: "index_quest_executions_on_active_quest", unique: true, where: "status IN ('queued', 'preparing', 'running')"
    t.index ["quest_id"], name: "index_quest_executions_on_quest_id"
    t.index ["quest_instruction_id"], name: "index_quest_executions_on_quest_instruction_id"
  end

  create_table "quest_instructions", force: :cascade do |t|
    t.integer "quest_id", null: false
    t.integer "sequence", null: false
    t.text "body", null: false
    t.string "status", default: "queued", null: false
    t.string "source_platform", null: false
    t.string "source_event_id"
    t.integer "external_resource_id"
    t.datetime "received_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["external_resource_id"], name: "index_quest_instructions_on_external_resource_id"
    t.index ["quest_id", "sequence"], name: "index_quest_instructions_on_quest_id_and_sequence", unique: true
    t.index ["quest_id", "status", "sequence"], name: "index_quest_instructions_on_quest_id_and_status_and_sequence"
    t.index ["quest_id"], name: "index_quest_instructions_on_quest_id"
    t.index ["source_platform", "source_event_id"], name: "index_quest_instructions_on_source_event", unique: true, where: "source_event_id IS NOT NULL"
  end

  create_table "quests", force: :cascade do |t|
    t.string "public_id", null: false
    t.string "title", null: false
    t.string "status", default: "pending", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["public_id"], name: "index_quests_on_public_id", unique: true
    t.index ["status"], name: "index_quests_on_status"
  end

  add_foreign_key "external_resources", "quests"
  add_foreign_key "quest_executions", "quest_instructions"
  add_foreign_key "quest_executions", "quests"
  add_foreign_key "quest_instructions", "external_resources"
  add_foreign_key "quest_instructions", "quests"
end
