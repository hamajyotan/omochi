require "test_helper"

class Omochi::Slack::EventHandlerTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @handler = Omochi::Slack::EventHandler.new
  end

  def build_envelope(
    event_id: "Ev001",
    envelope_id: "env_001",
    team_id: "T100",
    channel: "C200",
    ts: "1700000000.000100",
    thread_ts: nil,
    text: "<@U999BOT> Please investigate the failing test",
    extra_event: {}
  )
    {
      "envelope_id" => envelope_id,
      "type" => "events_api",
      "payload" => {
        "team_id" => team_id,
        "event_id" => event_id,
        "event" => {
          "type" => "app_mention",
          "user" => "U123USER",
          "text" => text,
          "ts" => ts,
          "thread_ts" => thread_ts,
          "channel" => channel
        }.compact.merge(extra_event)
      }
    }
  end

  test "creates a new Quest, ExternalResource, and Instruction from a top-level mention" do
    result = @handler.handle_envelope(build_envelope)

    assert_equal :accepted, result.status
    assert result.created_quest
    quest = result.instruction.quest
    assert_equal "Please investigate the failing test", result.instruction.body
    assert_equal "slack", result.instruction.source_platform
    assert_equal "Ev001", result.instruction.source_event_id

    resource = quest.external_resources.sole
    assert_equal "slack", resource.platform
    assert_equal "thread", resource.resource_type
    assert_equal "T100/C200", resource.scope_key
    assert_equal "1700000000.000100", resource.external_id
  end

  test "attaches a follow-up mention in the same thread to the existing Quest and reopens if completed" do
    first = @handler.handle_envelope(build_envelope(event_id: "Ev001", ts: "1700000000.000100"))
    quest = first.instruction.quest
    quest.claim_next_instruction!.succeed!(result_summary: "Done")
    assert quest.reload.completed?

    second = @handler.handle_envelope(
      build_envelope(
        event_id: "Ev002",
        ts: "1700000005.000200",
        thread_ts: "1700000000.000100",
        text: "<@U999BOT> Also update the README"
      )
    )

    assert_equal :accepted, second.status
    assert_not second.created_quest
    assert_equal quest, second.instruction.quest
    assert_equal 2, second.instruction.sequence
    assert_equal "Also update the README", second.instruction.body
    assert quest.reload.pending?
  end

  test "attaches a non-mention thread reply (type: message) in an existing Quest thread" do
    first = @handler.handle_envelope(build_envelope(event_id: "Ev001", ts: "1700000000.000100"))
    quest = first.instruction.quest
    quest.claim_next_instruction!.succeed!(result_summary: "Done")
    assert quest.reload.completed?

    follow_up = @handler.handle_envelope(
      build_envelope(
        event_id: "Ev002Msg",
        ts: "1700000010.000300",
        thread_ts: "1700000000.000100",
        text: "Thanks! Could you also check the edge cases?",
        extra_event: { "type" => "message" }
      )
    )

    assert_equal :accepted, follow_up.status
    assert_not follow_up.created_quest
    assert_equal quest, follow_up.instruction.quest
    assert_equal 2, follow_up.instruction.sequence
    assert_equal "Thanks! Could you also check the edge cases?", follow_up.instruction.body
    assert quest.reload.pending?
  end

  test "ignores non-mention thread reply in an unrelated thread and avoids duplicate when mentioning bot" do
    first = @handler.handle_envelope(build_envelope(event_id: "Ev001", ts: "1700000000.000100"))
    quest = first.instruction.quest

    assert_no_difference [ -> { Quest.count }, -> { QuestInstruction.count } ] do
      unrelated_thread = build_envelope(
        event_id: "EvUnrelated",
        ts: "1700000020.000400",
        thread_ts: "1700000999.999999",
        text: "Just chatting in another thread",
        extra_event: { "type" => "message" }
      )
      assert_equal :ignored, @handler.handle_envelope(unrelated_thread).status

      mention_as_message = build_envelope(
        event_id: "EvDupMentionMsg",
        ts: "1700000030.000500",
        thread_ts: "1700000000.000100",
        text: "<@U999BOT> Mentioning bot again",
        extra_event: { "type" => "message" }
      )
      assert_equal :ignored, @handler.handle_envelope(mention_as_message).status
    end

    assert_equal 1, quest.instructions.count
  end

  test "de-duplicates redelivered Slack events with the same event_id" do
    first = @handler.handle_envelope(build_envelope(event_id: "EvDup"))

    assert_no_difference [ -> { Quest.count }, -> { QuestInstruction.count } ] do
      second = @handler.handle_envelope(build_envelope(event_id: "EvDup"))
      assert_equal :duplicate, second.status
      assert second.duplicate
      assert_equal first.instruction, second.instruction
    end
  end

  test "ignores bot messages, message_changed subtypes, and non-mention events" do
    assert_no_difference -> { Quest.count } do
      bot_env = build_envelope(event_id: "EvBot", extra_event: { "bot_id" => "B123" })
      assert_equal :ignored, @handler.handle_envelope(bot_env).status

      edited_env = build_envelope(event_id: "EvEdit", extra_event: { "subtype" => "message_changed" })
      assert_equal :ignored, @handler.handle_envelope(edited_env).status

      other_env = build_envelope(event_id: "EvMsg", extra_event: { "type" => "message" })
      assert_equal :ignored, @handler.handle_envelope(other_env).status
    end
  end

  test "end-to-end Slack mention adds eyes reaction, runs Mock Agent, replies only the result, and removes eyes reaction" do
    perform_enqueued_jobs do
      @handler.handle_envelope(build_envelope(event_id: "EvE2E", text: "<@U999BOT> Ship the feature"))
    end

    quest = Quest.last
    assert quest.completed?

    assert_equal [ { channel: "C200", timestamp: "1700000000.000100", name: "eyes" } ], @fake_slack_client.reactions_added
    assert_equal [ { channel: "C200", timestamp: "1700000000.000100", name: "eyes" } ], @fake_slack_client.reactions_removed

    assert_equal 1, @fake_slack_client.posted_messages.size
    msg = @fake_slack_client.posted_messages.sole
    assert_equal "C200", msg[:channel]
    assert_equal "1700000000.000100", msg[:thread_ts]
    assert_includes msg[:text], "Ship the feature"
    assert_not_includes msg[:text], "Instruction #1 completed for"
  end

  test "Slack notification failure does not fail the QuestExecution" do
    @fake_slack_client.on_post_message = ->(**) { raise Omochi::Slack::ApiError, "slack down" }

    perform_enqueued_jobs do
      @handler.handle_envelope(build_envelope(event_id: "EvSlackDown", text: "<@U999BOT> Still run agent"))
    end

    quest = Quest.last
    assert quest.completed?
    assert quest.executions.sole.succeeded?
  end

  test "ignores events from other workspaces when SLACK_TEAM_ID is configured" do
    orig_team_id = Rails.configuration.omochi[:slack][:team_id]
    Rails.configuration.omochi[:slack][:team_id] = "T100"

    assert_no_difference -> { Quest.count } do
      other_team_env = build_envelope(event_id: "EvOtherTeam", team_id: "T_OTHER")
      assert_equal :ignored, @handler.handle_envelope(other_team_env).status
    end
  ensure
    Rails.configuration.omochi[:slack][:team_id] = orig_team_id
  end
end
