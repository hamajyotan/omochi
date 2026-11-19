require "test_helper"
require "tmpdir"

class Omochi::Docker::CliClientTest < ActiveSupport::TestCase
  test "builds isolated docker create arguments without leaking host credentials" do
    captured_args = nil
    fake_status = Struct.new(:exitstatus, :success?).new(0, true)
    fake_capture3 = ->(*args, **_opts) do
      captured_args = args
      [ "abc123container\n", "", fake_status ]
    end

    client = Omochi::Docker::CliClient.new(docker_bin: "docker", capture3: fake_capture3)
    cid = client.create_container(
      name: "omochi-test",
      image: "ruby:4.0",
      workspace_path: "/tmp/ws",
      agent_script_path: "/tmp/mock_agent.rb",
      memory: "512m",
      cpus: "1.0",
      pids_limit: 128,
      env: { "OMOCHI_QUEST_ID" => "qst_1" }
    )

    assert_equal "abc123container", cid
    assert_includes captured_args, "--network"
    assert_equal "none", captured_args[captured_args.index("--network") + 1]
    assert_includes captured_args, "--read-only"
    assert_includes captured_args, "/tmp:rw,nosuid,exec,mode=1777,size=512m"
    assert_includes captured_args, "/home/agent:rw,nosuid,exec,mode=1777,size=512m"
    assert_includes captured_args, "HOME=/home/agent"
    assert_includes captured_args, "OMOCHI_QUEST_ID=qst_1"
    assert_includes captured_args, "--cap-drop"
    assert_equal "ALL", captured_args[captured_args.index("--cap-drop") + 1]
    assert_includes captured_args, "no-new-privileges"
    assert_not captured_args.any? { |a| a.to_s.include?("SLACK_") || a.to_s.include?("GITHUB_") || a.to_s.include?("docker.sock") }
  end

  test "builds docker create arguments with custom command and network" do
    captured_args = nil
    fake_status = Struct.new(:exitstatus, :success?).new(0, true)
    fake_capture3 = ->(*args, **_opts) do
      captured_args = args
      [ "abc123container\n", "", fake_status ]
    end

    client = Omochi::Docker::CliClient.new(docker_bin: "docker", capture3: fake_capture3)
    client.create_container(
      name: "omochi-antigravity",
      image: "omochi-agent:antigravity",
      workspace_path: "/tmp/ws",
      agent_script_path: "/tmp/antigravity_agent.py",
      agent_instructions_path: "/tmp/agent_AGENTS.md",
      command: [ "python3", "/opt/omochi/agent_runner" ],
      network: "bridge",
      memory: "1g",
      cpus: "1.0",
      pids_limit: 128,
      env: { "GEMINI_API_KEY" => "test_key" }
    )

    assert_includes captured_args, "--network"
    assert_equal "bridge", captured_args[captured_args.index("--network") + 1]
    assert_includes captured_args, "omochi-agent:antigravity"
    assert_includes captured_args, "python3"
    assert_includes captured_args, "/opt/omochi/agent_runner"
    assert_includes captured_args, "/tmp/agent_AGENTS.md:/opt/omochi/AGENTS.md:ro"
  end

  test "executes mock_agent.rb end-to-end inside a real Docker container" do
    client = Omochi::Docker::CliClient.new
    Dir.mktmpdir("omochi_ws_") do |workspace|
      File.write(
        File.join(workspace, ".omochi_instruction.json"),
        JSON.generate(
          quest_public_id: "qst_01a1d836-32e2-7137-bec7-62f416cec9e0",
          execution_id: 1,
          instruction_sequence: 1,
          source_platform: "dashboard",
          body: "Real Docker smoke test",
          received_at: Time.current.iso8601
        )
      )

      cid = client.create_container(
        name: "omochi-smoke-#{SecureRandom.hex(4)}",
        image: Omochi::Settings.fetch!(:docker, :image),
        workspace_path: workspace,
        agent_script_path: Rails.root.join("agent/mock_agent.rb").to_s,
        memory: "256m",
        cpus: "1.0",
        pids_limit: 64,
        env: { "OMOCHI_QUEST_ID" => "qst_01a1d836-32e2-7137-bec7-62f416cec9e0" }
      )

      begin
        lines = []
        exit_code = client.run_attached(cid, timeout_seconds: 30) do |line, stream|
          lines << [ stream, line ]
        end

        assert_equal 0, exit_code
        events = lines.map { |stream, line| QuestExecutionEvent.parse_line(line, stream: stream) }
        assert_equal %w[started progress log progress completed], events.map { |e| e[:event_type] }
        assert File.exist?(File.join(workspace, "quest_log.md"))
      ensure
        assert client.remove_container(cid)
      end
    end
  end
end
