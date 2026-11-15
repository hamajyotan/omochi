require "test_helper"

class QuestExecutionDockerRunnerTest < ActiveSupport::TestCase
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
    orig_net = Rails.configuration.omochi[:docker][:network]

    Rails.configuration.omochi[:docker][:agent_runtime] = "antigravity"
    Rails.configuration.omochi[:docker][:gemini_api_key] = "secret_gemini_key"
    Rails.configuration.omochi[:docker][:network] = "bridge"

    begin
      quest = start_quest(body: "Antigravity task")
      execution = quest.claim_next_instruction!

      QuestExecution::DockerRunner.new(docker_client: @fake_docker_client).run(execution)

      spec = @fake_docker_client.created_containers.sole
      assert_equal [ "python3", Omochi::Docker::CliClient::CONTAINER_AGENT_PATH ], spec[:command]
      assert_equal "bridge", spec[:network]
      assert_equal "secret_gemini_key", spec[:env]["GEMINI_API_KEY"]
      assert_includes spec[:agent_script_path], "antigravity_agent.py"
    ensure
      Rails.configuration.omochi[:docker][:agent_runtime] = orig_runtime
      Rails.configuration.omochi[:docker][:gemini_api_key] = orig_key
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
end
