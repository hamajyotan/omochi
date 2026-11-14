require "test_helper"

class Omochi::Slack::SocketClientTest < ActiveSupport::TestCase
  test "persists the QuestInstruction in SQLite BEFORE sending the Socket Mode ACK" do
    persisted_count_at_ack = nil
    acks = []
    client = Omochi::Slack::SocketClient.new(web_client: @fake_slack_client)

    raw = JSON.generate(
      envelope_id: "env_ack_1",
      type: "events_api",
      payload: {
        team_id: "T1",
        event_id: "EvAckOrder",
        event: {
          type: "app_mention",
          user: "U1",
          text: "<@U999> Check ack order",
          ts: "1700000000.000100",
          channel: "C1"
        }
      }
    )

    status = client.process_raw_message(raw) do |ack_json|
      persisted_count_at_ack = QuestInstruction.where(source_platform: "slack", source_event_id: "EvAckOrder").count
      acks << JSON.parse(ack_json)
    end

    assert_equal :handled, status
    assert_equal 1, persisted_count_at_ack, "Instruction must be persisted before ACK is sent"
    assert_equal [ { "envelope_id" => "env_ack_1" } ], acks
  end

  test "returns :disconnect when Slack sends a disconnect envelope" do
    client = Omochi::Slack::SocketClient.new(web_client: @fake_slack_client)

    status = client.process_raw_message('{"type":"disconnect","reason":"refresh_requested"}')
    assert_equal :disconnect, status
  end
end
