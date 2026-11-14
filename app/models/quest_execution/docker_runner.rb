require "fileutils"

# Runs a QuestExecution inside an isolated Docker Container (Phase 2).
#
# Responsibilities:
# 1. Prepare a Quest-scoped workspace directory (`<workspaces_dir>/<quest_public_id>`)
#    and write `.omochi_instruction.json` into it.
# 2. Create a locked-down Agent Container (`--network none`, `--read-only`,
#    non-root, no credentials, no Docker socket).
# 3. Record `container_id` and transition the Execution to `running`.
# 4. Run the Container attached, persisting each structured JSONL event and
#    updating `heartbeat_at` outside long DB transactions.
# 5. Determine success (`exit_code == 0` AND a `completed` event was emitted) or
#    failure (`agent_error`, `container_error`, `timeout`).
# 6. Always attempt Container cleanup (`docker rm -f`), recording
#    `cleanup_status` (`completed` or `failed`) so `ReconcileQuestsJob` can retry
#    if cleanup fails.
class QuestExecution::DockerRunner
  HEARTBEAT_INTERVAL_SECONDS = 5.0
  INSTRUCTION_FILENAME = ".omochi_instruction.json".freeze

  class_attribute :docker_client_factory, default: -> { Omochi::Docker::CliClient.new }

  def initialize(docker_client: self.class.docker_client_factory.call)
    @docker_client = docker_client
  end

  def run(execution)
    workspace_path = prepare_workspace!(execution)
    execution.mark_preparing!(workspace_path: workspace_path.to_s)

    container_id = create_container!(execution, workspace_path)
    execution.mark_running!(container_id: container_id)

    completed_event = nil
    failed_event = nil
    last_heartbeat = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    exit_code = @docker_client.run_attached(
      container_id,
      timeout_seconds: docker_setting(:timeout_seconds).to_i,
      on_heartbeat: -> {
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if now - last_heartbeat >= HEARTBEAT_INTERVAL_SECONDS
          execution.touch_heartbeat!
          last_heartbeat = now
        end
      }
    ) do |line, stream|
      event = execution.record_output_line!(line, stream: stream)
      last_heartbeat = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      completed_event = event if event.event_type == "completed"
      failed_event = event if event.event_type == "failed"
    end

    finalize_execution!(execution, exit_code:, completed_event:, failed_event:)
  rescue Omochi::Docker::TimeoutError => e
    execution.fail!(error_kind: "timeout", error_message: e.message)
  rescue Omochi::Docker::Error => e
    execution.fail!(error_kind: "container_error", error_message: e.message)
  ensure
    cleanup_container!(execution)
  end

  private
    def prepare_workspace!(execution)
      quest = execution.quest
      instruction = execution.instruction

      base_dir = Rails.root.join(docker_setting(:workspaces_dir).to_s)
      workspace_dir = base_dir.join(quest.public_id)
      FileUtils.mkdir_p(workspace_dir)

      payload = {
        quest_public_id: quest.public_id,
        execution_id: execution.id,
        instruction_sequence: instruction.sequence,
        source_platform: instruction.source_platform,
        body: instruction.body,
        received_at: instruction.received_at.iso8601
      }
      File.write(workspace_dir.join(INSTRUCTION_FILENAME), JSON.pretty_generate(payload))
      workspace_dir
    end

    def create_container!(execution, workspace_path)
      container_name = "omochi-#{execution.quest.public_id}-exec-#{execution.id}"
      @docker_client.create_container(
        name: container_name,
        image: docker_setting(:image),
        workspace_path: workspace_path.to_s,
        agent_script_path: Rails.root.join("agent/mock_agent.rb").to_s,
        memory: docker_setting(:memory),
        cpus: docker_setting(:cpus),
        pids_limit: docker_setting(:pids_limit),
        env: {
          "OMOCHI_QUEST_ID" => execution.quest.public_id,
          "OMOCHI_EXECUTION_ID" => execution.id.to_s
        }
      )
    end

    def finalize_execution!(execution, exit_code:, completed_event:, failed_event:)
      if exit_code == 0 && completed_event && failed_event.nil?
        summary = completed_event.message.presence ||
          completed_event.payload["summary"].presence ||
          "Execution completed."
        execution.succeed!(result_summary: summary, exit_code: exit_code)
      else
        reason =
          if failed_event
            failed_event.message.presence || failed_event.payload["error"].presence || "Agent reported failure"
          elsif exit_code != 0
            "Agent exited with non-zero status #{exit_code}"
          else
            "Agent exited with status 0 without emitting a completed event"
          end
        execution.fail!(error_kind: "agent_error", error_message: reason, exit_code: exit_code)
      end
    end

    def cleanup_container!(execution)
      return if execution.container_id.blank?

      @docker_client.remove_container(execution.container_id)
      execution.mark_cleaned_up!
    rescue StandardError => e
      Rails.error.report(e, context: { execution_id: execution.id, container_id: execution.container_id })
      execution.mark_cleanup_failed!
    end

    def docker_setting(key)
      Omochi::Settings.fetch!(:docker, key)
    end
end
