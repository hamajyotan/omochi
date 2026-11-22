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
  ATTACHMENTS_DIRNAME = ".omochi_attachments".freeze

  class_attribute :docker_client_factory, default: -> { Omochi::Docker::CliClient.new }

  def initialize(
    docker_client: self.class.docker_client_factory.call,
    workspace_syncer: Omochi::GitHub.build_workspace_syncer,
    pull_request_merger: Omochi::GitHub::PullRequestMerger.new
  )
    @docker_client = docker_client
    @workspace_syncer = workspace_syncer
    @pull_request_merger = pull_request_merger
  end

  def run(execution)
    if Omochi::GitHub::PullRequestMerger.merge_command?(execution.instruction.body)
      return run_merge_command!(execution)
    end
    workspace_path, git_context = prepare_workspace!(execution)
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
      apply_memory_event!(execution, event) if event.event_type == "memory"
      execution.notify_slack_interim!(event.message) if event.event_type == "interim" && event.message.present?
      completed_event = event if event.event_type == "completed"
      failed_event = event if event.event_type == "failed"
    end

    finalize_execution!(
      execution,
      workspace_path: workspace_path,
      git_context: git_context,
      exit_code: exit_code,
      completed_event: completed_event,
      failed_event: failed_event
    )
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

      git_context = @workspace_syncer&.sync!(execution, workspace_dir)
      if git_context.is_a?(Hash)
        execution.record_event!(
          event_type: "progress",
          message: "Workspace synced: #{git_context['repository']} (mode: #{git_context['mode']}, checked_out: #{git_context['checked_out']})"
        )
      end
      attachments = prepare_attachments!(execution, workspace_dir)

      prior_history = quest.instructions
        .where("sequence < ?", instruction.sequence)
        .in_queue_order
        .includes(:executions)
        .map do |inst|
          succeeded_exec = inst.executions.select(&:succeeded?).last
          {
            sequence: inst.sequence,
            source_platform: inst.source_platform,
            speaker: inst.actor_identifier,
            body: inst.body,
            result_summary: succeeded_exec&.result_summary
          }.compact
        end

      user_memories =
        if (scope = instruction.memory_scope)
          AgentMemory.prompt_payload_for(scope_type: scope[0], scope_key: scope[1])
        end

      payload = {
        quest_public_id: quest.public_id,
        execution_id: execution.id,
        instruction_sequence: instruction.sequence,
        source_platform: instruction.source_platform,
        speaker: instruction.actor_identifier,
        body: instruction.body,
        received_at: instruction.received_at.iso8601,
        history: prior_history,
        git_context: git_context,
        attachments: attachments.presence,
        user_memories: user_memories
      }.compact
      File.write(workspace_dir.join(INSTRUCTION_FILENAME), JSON.pretty_generate(payload))
      [ workspace_dir, git_context ]
    end

    def create_container!(execution, workspace_path)
      container_name = "omochi-#{execution.quest.public_id}-exec-#{execution.id}"
      runtime = docker_setting_optional(:agent_runtime) || "mock"

      agent_script_path, agent_instructions_path, command =
        if runtime == "antigravity"
          instructions_path = Rails.root.join("agent/AGENTS.md").to_s
          [
            Rails.root.join("agent/antigravity_agent.py").to_s,
            (File.exist?(instructions_path) ? instructions_path : nil),
            [ "python3", Omochi::Docker::CliClient::CONTAINER_AGENT_PATH ]
          ]
        else
          [ Rails.root.join("agent/mock_agent.rb").to_s, nil, [ "ruby", Omochi::Docker::CliClient::CONTAINER_AGENT_PATH ] ]
        end

      env = {
        "OMOCHI_QUEST_ID" => execution.quest.public_id,
        "OMOCHI_EXECUTION_ID" => execution.id.to_s,
        "LANG" => "C.UTF-8",
        "LC_ALL" => "C.UTF-8"
      }
      if (api_key = docker_setting_optional(:gemini_api_key))
        env["GEMINI_API_KEY"] = api_key
      end
      if (gemini_model = docker_setting_optional(:gemini_model))
        env["GEMINI_MODEL"] = gemini_model
      end
      if (gemini_smart_model = docker_setting_optional(:gemini_smart_model))
        env["GEMINI_SMART_MODEL"] = gemini_smart_model
      end

      @docker_client.create_container(
        name: container_name,
        image: docker_setting(:image),
        workspace_path: workspace_path.to_s,
        agent_script_path: agent_script_path,
        agent_instructions_path: agent_instructions_path,
        command: command,
        network: docker_setting_optional(:network) || "none",
        memory: docker_setting(:memory),
        cpus: docker_setting(:cpus),
        pids_limit: docker_setting(:pids_limit),
        env: env
      )
    end

    def finalize_execution!(execution, workspace_path:, git_context:, exit_code:, completed_event:, failed_event:)
      if exit_code == 0 && completed_event && failed_event.nil?
        summary = completed_event.message.presence ||
          completed_event.payload["summary"].presence ||
          "Execution completed."

        publish_result = @workspace_syncer&.publish_changes!(
          execution,
          workspace_path,
          git_context: git_context,
          summary: summary
        )
        summary = append_publish_result_to_summary(summary, publish_result) if publish_result

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

    def append_publish_result_to_summary(summary, publish_result)
      if publish_result["action"] == "error"
        return "#{summary}\n\n⚠️ GitHub push failed: #{publish_result['error']}"
      end

      url = publish_result["url"].to_s
      return summary if url.blank? || summary.include?(url)

      case publish_result["action"]
      when "created_pr"
        "#{summary}\n\n🔗 Pull Request created: #{url}"
      when "updated_pr"
        "#{summary}\n\n🔗 Pushed #{publish_result['commits_count']} commit(s) to PR ##{publish_result['pull_number']}: #{url}"
      else
        summary
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

    def prepare_attachments!(execution, workspace_dir)
      raw_attachments = execution.instruction.metadata&.dig("attachments")
      return [] unless raw_attachments.is_a?(Array) && raw_attachments.any?

      attachments_dir = workspace_dir.join(ATTACHMENTS_DIRNAME)
      FileUtils.mkdir_p(attachments_dir)
      slack_client = Omochi::Slack.build_web_client

      raw_attachments.each_with_index.filter_map do |att, idx|
        url = att["url"].to_s
        next if url.blank?

        raw_name = File.basename(att["name"].to_s).gsub(/[^A-Za-z0-9._-]/, "_")
        raw_name = "attachment_#{idx + 1}.png" if raw_name.blank? || raw_name == "." || raw_name == ".."
        filename = "#{execution.instruction.sequence}_#{idx + 1}_#{raw_name}"
        host_path = attachments_dir.join(filename)

        bytes = slack_client.download_file(url)
        File.binwrite(host_path, bytes)

        {
          "name" => att["name"].to_s,
          "mimetype" => att["mimetype"].to_s,
          "path" => "/workspace/#{ATTACHMENTS_DIRNAME}/#{filename}"
        }
      rescue StandardError => e
        Rails.error.report(e, context: { execution_id: execution.id, attachment_url: url })
        nil
      end
    end

    def run_merge_command!(execution)
      execution.mark_running!
      execution.record_event!(
        event_type: "progress",
        message: "Merging Pull Request via GitHub App API..."
      )

      result = @pull_request_merger.merge!(execution)
      summary = "🔀 Merged Pull Request ##{result['pull_number']} (#{result['merge_method']}): #{result['url']}"
      execution.record_event!(event_type: "completed", message: summary, payload: result)
      execution.succeed!(result_summary: summary, exit_code: 0)
    rescue Omochi::GitHub::PullRequestMerger::MergeError, Omochi::GitHub::Error => e
      execution.fail!(error_kind: "agent_error", error_message: "Pull Request のマージに失敗しました: #{e.message}")
    end

    def apply_memory_event!(execution, event)
      scope = execution.instruction.memory_scope
      return unless scope

      AgentMemory.apply_event!(
        scope_type: scope[0],
        scope_key: scope[1],
        payload: event.payload,
        quest_public_id: execution.quest.public_id
      )
    rescue StandardError => e
      Rails.error.report(e, context: { execution_id: execution.id, event_id: event.id })
    end

    def docker_setting(key)
      Omochi::Settings.fetch!(:docker, key)
    end

    def docker_setting_optional(key)
      Omochi::Settings.dig(:docker, key)
    end
end
