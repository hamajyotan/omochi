require "test_helper"

class QuestExecutionDockerRunnerTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "runs mock agent in an isolated container, persists events, and cleans up" do
    quest = start_quest(body: "Build feature X")
    execution = quest.claim_next_instruction!

    QuestExecution::DockerRunner.new(docker_client: @fake_docker_client).run(execution)

    execution.reload
    assert execution.succeeded?
    assert_equal 0, execution.exit_code
    assert_equal "completed", execution.cleanup_status
    assert_includes execution.result_summary, "Build feature X"
    assert_equal %w[started progress log completed], execution.events.pluck(:event_type)
    assert_equal [ execution.container_id ], @fake_docker_client.removed_containers
    assert quest.reload.completed?

    spec = @fake_docker_client.created_containers.sole
    assert_equal({ "OMOCHI_QUEST_ID" => quest.public_id, "OMOCHI_EXECUTION_ID" => execution.id.to_s, "LANG" => "C.UTF-8", "LC_ALL" => "C.UTF-8" }, spec[:env])
    assert File.exist?(File.join(execution.workspace_path, "quest_log.md"))
  end

  test "persists workspace across multiple executions of the same quest" do
    quest = start_quest(body: "Step one")
    quest.receive_instruction!(body: "Step two", source_platform: "dashboard")

    first = quest.claim_next_instruction!
    QuestExecution::DockerRunner.new(docker_client: @fake_docker_client).run(first)

    second = quest.claim_next_instruction!
    QuestExecution::DockerRunner.new(docker_client: @fake_docker_client).run(second)

    assert_equal first.workspace_path, second.workspace_path
    assert_not_equal first.container_id, second.container_id
    log_content = File.read(File.join(second.workspace_path, "quest_log.md"))
    assert_includes log_content, "Step one"
    assert_includes log_content, "Step two"
  end

  test "marks execution as agent_error when mock agent fails" do
    quest = start_quest(body: "Please fail [mock:fail]")
    execution = quest.claim_next_instruction!

    QuestExecution::DockerRunner.new(docker_client: @fake_docker_client).run(execution)

    execution.reload
    assert execution.failed?
    assert_equal "agent_error", execution.error_kind
    assert_equal 2, execution.exit_code
    assert_includes execution.error_message, "simulated failure"
    assert_equal "completed", execution.cleanup_status
    assert quest.reload.failed?
  end

  test "configures antigravity runtime with python command and gemini api key" do
    orig_runtime = Rails.configuration.omochi[:docker][:agent_runtime]
    orig_key = Rails.configuration.omochi[:docker][:gemini_api_key]
    orig_model = Rails.configuration.omochi[:docker][:gemini_model]
    orig_smart_model = Rails.configuration.omochi[:docker][:gemini_smart_model]
    orig_net = Rails.configuration.omochi[:docker][:network]

    Rails.configuration.omochi[:docker][:agent_runtime] = "antigravity"
    Rails.configuration.omochi[:docker][:gemini_api_key] = "secret_gemini_key"
    Rails.configuration.omochi[:docker][:gemini_model] = "gemini-3.1-flash-lite"
    Rails.configuration.omochi[:docker][:gemini_smart_model] = "gemini-3.5-flash"
    Rails.configuration.omochi[:docker][:network] = "bridge"

    begin
      quest = start_quest(body: "Antigravity task")
      execution = quest.claim_next_instruction!

      QuestExecution::DockerRunner.new(docker_client: @fake_docker_client).run(execution)

      spec = @fake_docker_client.created_containers.sole
      assert_equal [ "python3", Omochi::Docker::CliClient::CONTAINER_AGENT_PATH ], spec[:command]
      assert_equal "bridge", spec[:network]
      assert_equal "secret_gemini_key", spec[:env]["GEMINI_API_KEY"]
      assert_equal "gemini-3.1-flash-lite", spec[:env]["GEMINI_MODEL"]
      assert_equal "gemini-3.5-flash", spec[:env]["GEMINI_SMART_MODEL"]
      assert_includes spec[:agent_script_path], "antigravity_agent.py"
      assert_includes spec[:agent_instructions_path], "agent/AGENTS.md"
    ensure
      Rails.configuration.omochi[:docker][:agent_runtime] = orig_runtime
      Rails.configuration.omochi[:docker][:gemini_api_key] = orig_key
      Rails.configuration.omochi[:docker][:gemini_model] = orig_model
      Rails.configuration.omochi[:docker][:gemini_smart_model] = orig_smart_model
      Rails.configuration.omochi[:docker][:network] = orig_net
    end
  end

  test "marks execution as agent_error when exit code is 0 without a completed event" do
    @fake_docker_client.on_run = ->(_cid, **, &block) do
      block.call(%({"type":"started","message":"hi"}\n), "stdout")
      0
    end
    quest = start_quest
    execution = quest.claim_next_instruction!

    QuestExecution::DockerRunner.new(docker_client: @fake_docker_client).run(execution)

    execution.reload
    assert execution.failed?
    assert_equal "agent_error", execution.error_kind
    assert_includes execution.error_message, "without emitting a completed event"
  end

  test "marks execution as container_error when docker create fails" do
    @fake_docker_client.on_create = ->(_spec) { raise Omochi::Docker::Error, "daemon unreachable" }
    quest = start_quest
    execution = quest.claim_next_instruction!

    QuestExecution::DockerRunner.new(docker_client: @fake_docker_client).run(execution)

    execution.reload
    assert execution.failed?
    assert_equal "container_error", execution.error_kind
    assert_includes execution.error_message, "daemon unreachable"
    assert_equal "not_needed", execution.cleanup_status
  end

  test "marks execution as timeout and still cleans up the container" do
    @fake_docker_client.on_run = ->(cid, **) { raise Omochi::Docker::TimeoutError, "Container #{cid} timed out" }
    quest = start_quest
    execution = quest.claim_next_instruction!

    QuestExecution::DockerRunner.new(docker_client: @fake_docker_client).run(execution)

    execution.reload
    assert execution.failed?
    assert_equal "timeout", execution.error_kind
    assert_equal "completed", execution.cleanup_status
    assert_equal [ execution.container_id ], @fake_docker_client.removed_containers
  end

  test "records cleanup_status failed when container removal fails without losing execution result" do
    @fake_docker_client.on_remove = ->(_cid) { raise Omochi::Docker::Error, "rm failed" }
    quest = start_quest
    execution = quest.claim_next_instruction!

    QuestExecution::DockerRunner.new(docker_client: @fake_docker_client).run(execution)

    execution.reload
    assert execution.succeeded?
    assert_equal "failed", execution.cleanup_status
  end

  test "injects user_memories into instruction payload and persists emitted memory events" do
    AgentMemory.apply_event!(
      scope_type: "user",
      scope_key: "slack:U777",
      payload: { "key" => "name", "category" => "profile", "content" => "名前は太郎" }
    )

    instruction = Quest.start!(
      title: "Slack memory quest",
      body: "こんにちは",
      source_platform: "slack",
      source_event_id: "Ev_mem_1",
      metadata: { "slack_user_id" => "U777", "slack_message_ts" => "1700000000.0001" },
      enqueue: false
    )
    execution = instruction.quest.claim_next_instruction!

    captured_instruction = nil
    @fake_docker_client.on_run = ->(_cid, **_opts, &block) do
      ws = @fake_docker_client.created_containers.last[:workspace_path]
      captured_instruction = JSON.parse(File.read(File.join(ws, ".omochi_instruction.json")))
      block.call(%({"type":"started","message":"hi"}\n), "stdout")
      block.call(%({"type":"memory","action":"upsert","key":"todo_mise","category":"follow_up","content":"Ruby 3.4 の検証予定"}\n), "stdout")
      block.call(%({"type":"completed","summary":"こんにちはにゃ！"}\n), "stdout")
      0
    end

    QuestExecution::DockerRunner.new(docker_client: @fake_docker_client).run(execution)

    assert_equal "user:slack:U777", captured_instruction.dig("user_memories", "scope")
    assert_equal "名前は太郎", captured_instruction.dig("user_memories", "items", 0, "content")

    learned = AgentMemory.find_by(scope_type: "user", scope_key: "slack:U777", memory_key: "todo_mise")
    assert_not_nil learned
    assert_equal "follow_up", learned.category
    assert_equal "Ruby 3.4 の検証予定", learned.content
  end

  test "distinguishes speakers in thread history and scopes memories to current speaker" do
    AgentMemory.apply_event!(
      scope_type: "user",
      scope_key: "slack:U_ALICE",
      payload: { "key" => "name", "category" => "profile", "content" => "名前は Alice" }
    )

    first_instruction = Quest.start!(
      title: "Multi-speaker Slack quest",
      body: "こんにちは、Alice です",
      source_platform: "slack",
      source_event_id: "Ev_alice_1",
      metadata: { "slack_user_id" => "U_ALICE", "slack_message_ts" => "1700000001.0001" },
      enqueue: false
    )
    first_exec = first_instruction.quest.claim_next_instruction!
    QuestExecution::DockerRunner.new(docker_client: @fake_docker_client).run(first_exec)

    second_instruction = first_instruction.quest.receive_instruction!(
      body: "途中から参加した Bob です",
      source_platform: "slack",
      source_event_id: "Ev_bob_2",
      metadata: { "slack_user_id" => "U_BOB", "slack_message_ts" => "1700000002.0001" },
      enqueue: false
    )
    second_exec = first_instruction.quest.claim_next_instruction!

    bob_payload = nil
    @fake_docker_client.on_run = ->(_cid, **_opts, &block) do
      ws = @fake_docker_client.created_containers.last[:workspace_path]
      bob_payload = JSON.parse(File.read(File.join(ws, ".omochi_instruction.json")))
      block.call(%({"type":"started","message":"hi"}\n), "stdout")
      block.call(%({"type":"completed","summary":"Bob さんもよろしくにゃ！"}\n), "stdout")
      0
    end

    QuestExecution::DockerRunner.new(docker_client: @fake_docker_client).run(second_exec)

    assert_equal "slack:U_BOB", bob_payload["speaker"]
    assert_nil bob_payload["user_memories"]
    assert_equal 1, bob_payload["history"].size
    assert_equal "slack:U_ALICE", bob_payload.dig("history", 0, "speaker")
  end

  test "streams interim events to Slack immediately without removing eyes reaction until completion" do
    instruction = Quest.start!(
      title: "Streaming interim quest",
      body: "調査して直して",
      source_platform: "slack",
      source_event_id: "Ev_interim_1",
      external_resource: {
        platform: "slack",
        resource_type: "thread",
        scope_key: "T1/C1",
        external_id: "1700000005.0001"
      },
      metadata: { "slack_message_ts" => "1700000005.0001" },
      enqueue: false
    )
    execution = instruction.quest.claim_next_instruction!

    @fake_docker_client.on_run = ->(_cid, **_opts, &block) do
      block.call(%({"type":"started","message":"hi"}\n), "stdout")
      block.call(%({"type":"interim","message":"まずはファイルを確認してみるにゃ！"}\n), "stdout")
      block.call(%({"type":"completed","summary":"修正が完了しましたにゃ！"}\n), "stdout")
      0
    end

    assert_enqueued_jobs 2, only: SlackNotificationJob do
      QuestExecution::DockerRunner.new(docker_client: @fake_docker_client).run(execution)
    end

    interim_job, final_job = enqueued_jobs.select { |j| j["job_class"] == "SlackNotificationJob" }.last(2)
    assert_equal "まずはファイルを確認してみるにゃ！", interim_job["arguments"][1]
    assert_nil interim_job["arguments"][2]["remove_reaction_ts"]

    assert_includes final_job["arguments"][1], "修正が完了しましたにゃ！"
    assert_equal "1700000005.0001", final_job["arguments"][2]["remove_reaction_ts"]
  end
end
