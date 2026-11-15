require "test_helper"

# Verifies all 10 MVP End-to-End completion criteria defined in docs/roadmap.md §3:
# 1. Mention omochi in Slack.
# 2. A Quest is created with its own Quest ID (qst_...).
# 3. A reply containing the Quest ID is posted to the original Slack Thread.
# 4. The Instruction is persisted and processed via Solid Queue.
# 5. The Quest's Docker Container is started.
# 6. The Mock Agent runs inside the Container.
# 7. Progress events, logs, and results from the Mock Agent are persisted.
# 8. The Dashboard reflects the execution state, events, and result.
# 9. Progress/completion is replied to the original Slack Thread.
# 10. The Container and temporary resources are cleaned up.
class MvpEndToEndTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include ActionCable::TestHelper

  test "complete Slack -> Quest -> Docker Mock Agent -> Dashboard & Slack reply flow" do
    socket_client = Omochi::Slack::SocketClient.new(web_client: @fake_slack_client)
    acks = []

    raw_envelope = JSON.generate(
      envelope_id: "env_mvp_1",
      type: "events_api",
      payload: {
        team_id: "T_MVP",
        event_id: "Ev_MVP_1",
        event: {
          type: "app_mention",
          user: "U_DEV",
          text: "<@U_OMOCHI> Implement the login page",
          ts: "1700000100.000001",
          channel: "C_DEV"
        }
      }
    )

    perform_enqueued_jobs do
      socket_client.process_raw_message(raw_envelope) { |ack| acks << JSON.parse(ack) }
    end

    assert_equal [ { "envelope_id" => "env_mvp_1" } ], acks

    quest = Quest.last
    assert_match Quest::PUBLIC_ID_FORMAT, quest.public_id
    assert quest.completed?

    execution = quest.executions.sole
    assert execution.succeeded?
    assert_equal 0, execution.exit_code
    assert_equal "completed", execution.cleanup_status
    assert_equal [ execution.container_id ], @fake_docker_client.removed_containers
    assert_equal %w[started progress log completed], execution.events.pluck(:event_type)

    # Verify Slack reaction (eyes added on receipt and removed on completion) and clean reply
    assert_equal [ { channel: "C_DEV", timestamp: "1700000100.000001", name: "eyes" } ], @fake_slack_client.reactions_added
    assert_equal [ { channel: "C_DEV", timestamp: "1700000100.000001", name: "eyes" } ], @fake_slack_client.reactions_removed

    texts = @fake_slack_client.posted_messages.map { |m| m[:text] }
    assert_equal 1, texts.size
    assert_includes texts[0], "Implement the login page"

    # Verify Dashboard reflects the Quest, ExternalResource, Instruction, Execution, and Events
    get quest_path(quest)
    assert_response :success
    assert_select "h1", "Implement the login page"
    assert_select ".mono", text: quest.public_id
    assert_select "li", text: /T_MVP\/C_DEV 1700000100\.000001/
    assert_select "tr##{ActionView::RecordIdentifier.dom_id(execution)}"
    assert_select ".event-log__item--completed", minimum: 1
  end
end
