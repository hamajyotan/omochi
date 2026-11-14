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

  test "end-to-end Slack mention runs Mock Agent and replies receipt, start, and completion to the thread" do
    perform_enqueued_jobs do
      @handler.handle_envelope(build_envelope(event_id: "EvE2E", text: "<@U999BOT> Ship the feature"))
    end

    quest = Quest.last
    assert quest.completed?
    assert_equal 3, @fake_slack_client.posted_messages.size

    receipt, started, finished = @fake_slack_client.posted_messages.map { |m| m[:text] }
    assert_includes receipt, "Quest created: `#{quest.public_id}`"
    assert_includes started, "Running instruction #1 for `#{quest.public_id}`"
    assert_includes finished, "Instruction #1 completed for `#{quest.public_id}`"
    assert_includes finished, "Ship the feature"

    @fake_slack_client.posted_messages.each do |msg|
      assert_equal "C200", msg[:channel]
      assert_equal "1700000000.000100", msg[:thread_ts]
    end
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
end
