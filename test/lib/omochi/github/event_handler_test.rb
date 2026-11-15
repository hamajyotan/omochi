require "test_helper"

class Omochi::GitHub::EventHandlerTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @handler = Omochi::GitHub::EventHandler.new
  end

  def build_pr_payload(action: "review_requested", reviewer: "omochi", pr_number: 42)
    {
      "action" => action,
      "pull_request" => {
        "number" => pr_number,
        "title" => "Add login feature",
        "html_url" => "https://github.com/hamajyotan/omochi/pull/#{pr_number}",
        "body" => "Please review my login feature",
        "user" => { "login" => "dev_user" },
        "base" => { "ref" => "main" },
        "head" => { "ref" => "feature-login", "sha" => "abc123sha" }
      },
      "repository" => {
        "full_name" => "hamajyotan/omochi"
      },
      "requested_reviewer" => {
        "login" => reviewer
      }
    }
  end

  test "review_requested for omochi creates a Quest and ExternalResource" do
    payload = build_pr_payload(reviewer: "omochi[bot]")
    result = @handler.handle(event_type: "pull_request", delivery_id: "deliv_1", payload: payload)

    assert_equal :accepted, result.status
    assert result.created_quest
    quest = result.instruction.quest
    assert_includes quest.title, "Review PR #42"
    assert_includes result.instruction.body, "Add login feature"
    assert_equal "github", result.instruction.source_platform
    assert_equal "deliv_1", result.instruction.source_event_id

    resource = quest.external_resources.sole
    assert_equal "github", resource.platform
    assert_equal "pull_request", resource.resource_type
    assert_equal "hamajyotan/omochi", resource.scope_key
    assert_equal "42", resource.external_id
    assert_equal "https://github.com/hamajyotan/omochi/pull/42", resource.url
  end

  test "review_requested for another user is ignored" do
    payload = build_pr_payload(reviewer: "other_reviewer")
    result = @handler.handle(event_type: "pull_request", delivery_id: "deliv_2", payload: payload)

    assert_equal :ignored, result.status
    assert_nil result.instruction
  end

  test "duplicate delivery_id is de-duplicated" do
    payload = build_pr_payload
    first = @handler.handle(event_type: "pull_request", delivery_id: "deliv_dup", payload: payload)

    assert_no_difference [ -> { Quest.count }, -> { QuestInstruction.count } ] do
      second = @handler.handle(event_type: "pull_request", delivery_id: "deliv_dup", payload: payload)
      assert_equal :duplicate, second.status
      assert_equal first.instruction, second.instruction
    end
  end

  test "issue_comment on existing Quest creates a follow-up instruction" do
    # First create PR Quest
    @handler.handle(event_type: "pull_request", delivery_id: "deliv_pr", payload: build_pr_payload)
    quest = Quest.last

    comment_payload = {
      "action" => "created",
      "issue" => {
        "number" => 42,
        "pull_request" => {} # indicates it is a PR
      },
      "comment" => {
        "body" => "I updated the auth logic as requested",
        "user" => { "login" => "dev_user", "type" => "User" }
      },
      "repository" => {
        "full_name" => "hamajyotan/omochi"
      }
    }

    result = @handler.handle(event_type: "issue_comment", delivery_id: "deliv_comment", payload: comment_payload)

    assert_equal :accepted, result.status
    assert_not result.created_quest
    assert_equal quest, result.instruction.quest
    assert_equal 2, result.instruction.sequence
    assert_equal "I updated the auth logic as requested", result.instruction.body
  end

  test "issue_comment mentioning @omochi-agent on unlinked PR starts a new Quest" do
    comment_payload = {
      "action" => "created",
      "issue" => {
        "number" => 99,
        "title" => "Refactor background worker",
        "html_url" => "https://github.com/hamajyotan/omochi/pull/99",
        "body" => "Initial description",
        "pull_request" => {}
      },
      "comment" => {
        "body" => "@omochi-agent レビューをお願いします",
        "user" => { "login" => "dev_user", "type" => "User" }
      },
      "repository" => {
        "full_name" => "hamajyotan/omochi"
      }
    }

    result = @handler.handle(event_type: "issue_comment", delivery_id: "deliv_mention", payload: comment_payload)

    assert_equal :accepted, result.status
    assert result.created_quest
    quest = result.instruction.quest
    assert_includes quest.title, "Review PR #99: Refactor background worker"
    assert_includes result.instruction.body, "@omochi-agent レビューをお願いします"
    assert_includes result.instruction.body, "Initial description"

    resource = quest.external_resources.sole
    assert_equal "github", resource.platform
    assert_equal "pull_request", resource.resource_type
    assert_equal "hamajyotan/omochi", resource.scope_key
    assert_equal "99", resource.external_id
    assert_equal "https://github.com/hamajyotan/omochi/pull/99", resource.url
  end

  test "issue_comment on unlinked PR without mention is ignored" do
    comment_payload = {
      "action" => "created",
      "issue" => {
        "number" => 99,
        "title" => "Refactor background worker",
        "pull_request" => {}
      },
      "comment" => {
        "body" => "Looks interesting!",
        "user" => { "login" => "dev_user", "type" => "User" }
      },
      "repository" => {
        "full_name" => "hamajyotan/omochi"
      }
    }

    result = @handler.handle(event_type: "issue_comment", delivery_id: "deliv_no_mention", payload: comment_payload)
    assert_equal :ignored, result.status
    assert_nil result.instruction
  end

  test "pull_request opened mentioning @omochi in description starts a new Quest" do
    payload = build_pr_payload(action: "opened", pr_number: 105)
    payload["pull_request"]["body"] = "Please review @omochi"
    payload.delete("requested_reviewer")

    result = @handler.handle(event_type: "pull_request", delivery_id: "deliv_opened", payload: payload)

    assert_equal :accepted, result.status
    assert result.created_quest
    assert_includes result.instruction.quest.title, "Review PR #105"
  end

  test "issue_comment with /review slash command starts a new Quest" do
    comment_payload = {
      "action" => "created",
      "issue" => {
        "number" => 101,
        "title" => "Add slash commands",
        "html_url" => "https://github.com/hamajyotan/omochi/pull/101",
        "pull_request" => {}
      },
      "comment" => {
        "body" => "/review お願いします",
        "user" => { "login" => "dev_user", "type" => "User" }
      },
      "repository" => {
        "full_name" => "hamajyotan/omochi"
      }
    }

    result = @handler.handle(event_type: "issue_comment", delivery_id: "deliv_slash_review", payload: comment_payload)

    assert_equal :accepted, result.status
    assert result.created_quest
    assert_includes result.instruction.quest.title, "Review PR #101"
  end

  test "issue_comment with /omochi slash command starts a new Quest" do
    comment_payload = {
      "action" => "created",
      "issue" => {
        "number" => 102,
        "title" => "Add omochi command",
        "html_url" => "https://github.com/hamajyotan/omochi/pull/102",
        "pull_request" => {}
      },
      "comment" => {
        "body" => "/omochi チェックして",
        "user" => { "login" => "dev_user", "type" => "User" }
      },
      "repository" => {
        "full_name" => "hamajyotan/omochi"
      }
    }

    result = @handler.handle(event_type: "issue_comment", delivery_id: "deliv_slash_omochi", payload: comment_payload)

    assert_equal :accepted, result.status
    assert result.created_quest
    assert_includes result.instruction.quest.title, "Review PR #102"
  end
end
