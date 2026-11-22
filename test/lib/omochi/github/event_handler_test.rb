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

  test "issue_comment on existing Quest with slash command creates a follow-up instruction" do
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
        "body" => "/review I updated the auth logic as requested",
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
    assert_equal "/review I updated the auth logic as requested", result.instruction.body
  end

  test "issue_comment on existing Quest without slash command is ignored" do
    @handler.handle(event_type: "pull_request", delivery_id: "deliv_pr", payload: build_pr_payload)

    comment_payload = {
      "action" => "created",
      "issue" => {
        "number" => 42,
        "pull_request" => {}
      },
      "comment" => {
        "body" => "Just a discussion between humans",
        "user" => { "login" => "dev_user", "type" => "User" }
      },
      "repository" => {
        "full_name" => "hamajyotan/omochi"
      }
    }

    result = @handler.handle(event_type: "issue_comment", delivery_id: "deliv_comment_human", payload: comment_payload)
    assert_equal :ignored, result.status
    assert_nil result.instruction
  end

  test "issue_comment with @omochi-agent or @omochi mention is ignored" do
    [ "@omochi-agent レビューをお願いします", "@omochi review", "@omochi-agent[bot] please" ].each do |body|
      comment_payload = {
        "action" => "created",
        "issue" => {
          "number" => 99,
          "title" => "Refactor background worker",
          "html_url" => "https://github.com/hamajyotan/omochi/pull/99",
          "pull_request" => {}
        },
        "comment" => {
          "body" => body,
          "user" => { "login" => "dev_user", "type" => "User" }
        },
        "repository" => {
          "full_name" => "hamajyotan/omochi"
        }
      }

      result = @handler.handle(event_type: "issue_comment", delivery_id: "deliv_mention_#{body.hash}", payload: comment_payload)
      assert_equal :ignored, result.status, "Expected #{body} to be ignored"
      assert_nil result.instruction
    end
  end

  test "issue_comment on unlinked PR without slash command is ignored" do
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

  test "pull_request opened with /review in description starts a new Quest" do
    payload = build_pr_payload(action: "opened", pr_number: 105)
    payload["pull_request"]["body"] = "Please /review"
    payload.delete("requested_reviewer")

    result = @handler.handle(event_type: "pull_request", delivery_id: "deliv_opened_review", payload: payload)

    assert_equal :accepted, result.status
    assert result.created_quest
    assert_includes result.instruction.quest.title, "Review PR #105"
  end

  test "pull_request opened with @omochi mention in description is ignored" do
    payload = build_pr_payload(action: "opened", pr_number: 106)
    payload["pull_request"]["body"] = "Please review @omochi"
    payload.delete("requested_reviewer")

    result = @handler.handle(event_type: "pull_request", delivery_id: "deliv_opened_mention", payload: payload)

    assert_equal :ignored, result.status
    assert_nil result.instruction
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

  test "ignores webhooks from repositories not listed in GITHUB_REPOSITORIES" do
    payload = build_pr_payload(reviewer: "omochi")
    payload["repository"]["full_name"] = "untrusted/other-repo"

    result = @handler.handle(event_type: "pull_request", delivery_id: "deliv_untrusted", payload: payload)

    assert_equal :ignored, result.status
    assert_nil result.instruction
  end

  test "accepts webhooks from repositories added to GITHUB_REPOSITORIES" do
    orig_repos = Rails.configuration.omochi[:github][:repositories]
    Rails.configuration.omochi[:github][:repositories] = "hamajyotan/omochi,daraz-tek/daraz-tek.github.io"

    begin
      payload = build_pr_payload(reviewer: "omochi", pr_number: 7)
      payload["repository"]["full_name"] = "daraz-tek/daraz-tek.github.io"
      payload["pull_request"]["html_url"] = "https://github.com/daraz-tek/daraz-tek.github.io/pull/7"

      result = @handler.handle(event_type: "pull_request", delivery_id: "deliv_org_repo", payload: payload)

      assert_equal :accepted, result.status
      assert result.created_quest
      assert_equal "daraz-tek/daraz-tek.github.io", result.instruction.external_resource.scope_key
    ensure
      Rails.configuration.omochi[:github][:repositories] = orig_repos
    end
  end

  test "accepts PR issue_comment without slash command when PR has omochi label" do
    comment_payload = {
      "action" => "created",
      "issue" => {
        "number" => 77,
        "title" => "Labeled PR",
        "html_url" => "https://github.com/hamajyotan/omochi/pull/77",
        "pull_request" => {},
        "labels" => [ { "name" => "omochi" } ]
      },
      "comment" => {
        "body" => "ここを直してください",
        "user" => { "login" => "dev_user", "type" => "User" }
      },
      "repository" => {
        "full_name" => "hamajyotan/omochi"
      }
    }

    result = @handler.handle(event_type: "issue_comment", delivery_id: "deliv_labeled_pr", payload: comment_payload)

    assert_equal :accepted, result.status
    assert result.created_quest
    assert_includes result.instruction.body, "ここを直してください"
  end
end
