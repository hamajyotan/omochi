require "test_helper"

class QuestsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  test "index lists quests" do
    quest = start_quest(title: "Visible quest")

    get root_path

    assert_response :success
    assert_select "td", text: "Visible quest"
    assert_select "a[href=?]", quest_path(quest.public_id)
  end

  test "index shows an empty state" do
    get quests_path

    assert_response :success
    assert_select ".empty"
  end

  test "show displays instructions and executions by public id" do
    quest = start_quest(title: "Detail", body: "Do the thing")
    perform_enqueued_jobs

    get quest_path(quest)

    assert_response :success
    assert_select "h1", "Detail"
    assert_select "td", text: "Do the thing"
    assert_select "#executions, table tr[id^=quest_execution_]", minimum: 1
  end

  test "show does not accept the internal id" do
    quest = start_quest

    get quest_path(quest.id)

    assert_response :not_found
  end

  test "create starts a quest with its first instruction" do
    assert_difference -> { Quest.count } => 1, -> { QuestInstruction.count } => 1 do
      post quests_path, params: { quest_form: { title: "New", body: "First instruction" } }
    end

    quest = Quest.last
    assert_redirected_to quest_path(quest)
    assert_equal "dashboard", quest.instructions.first.source_platform
    assert_enqueued_with(job: QuestProcessingJob)
  end

  test "create re-renders the form when invalid" do
    assert_no_difference -> { Quest.count } do
      post quests_path, params: { quest_form: { title: "", body: "" } }
    end

    assert_response :unprocessable_content
  end

  test "adding an instruction queues it on the quest" do
    quest = start_quest

    assert_difference -> { quest.instructions.count } do
      post quest_instructions_path(quest), params: { quest_instruction: { body: "More" } }
    end

    assert_redirected_to quest_path(quest)
    assert_equal "More", quest.instructions.last.body
  end

  test "adding a blank instruction shows an error" do
    quest = start_quest

    assert_no_difference -> { QuestInstruction.count } do
      post quest_instructions_path(quest), params: { quest_instruction: { body: " " } }
    end

    assert_redirected_to quest_path(quest)
    assert_not_nil flash[:alert]
  end
end
