require "securerandom"

# In-memory test double for `Omochi::Docker::CliClient`.
#
# By default it simulates a successful Mock Agent run that reads
# `.omochi_instruction.json` in the workspace and emits `started`, `progress`,
# `log`, and `completed` JSONL events without touching the Docker daemon.
# Individual tests can customize behaviour via `on_create`, `on_run`, or
# `on_remove`.
module Omochi
  module Docker
    class FakeClient
      attr_reader :created_containers, :removed_containers, :stopped_containers
      attr_accessor :on_create, :on_run, :on_remove

      def initialize
        @created_containers = []
        @removed_containers = []
        @stopped_containers = []
      end

      def create_container(**spec)
        return @on_create.call(spec) if @on_create

        container_id = "fake_ctr_#{SecureRandom.hex(6)}"
        @created_containers << spec.merge(container_id: container_id)
        container_id
      end

      def run_attached(container_id, timeout_seconds:, on_heartbeat: nil, &block)
        on_heartbeat&.call
        return @on_run.call(container_id, timeout_seconds: timeout_seconds, on_heartbeat: on_heartbeat, &block) if @on_run

        spec = @created_containers.find { |c| c[:container_id] == container_id }
        instruction_file = File.join(spec[:workspace_path], ".omochi_instruction.json") if spec
        instruction = instruction_file && File.exist?(instruction_file) ? JSON.parse(File.read(instruction_file)) : {}
        seq = instruction["instruction_sequence"] || 1
        body = instruction["body"].to_s

        emit(block, type: "started", message: "Mock agent starting (instruction ##{seq})")
        emit(block, type: "progress", message: "Inspecting workspace", data: { step: 1, total: 2 })
        emit(block, type: "log", stream: "stdout", message: "Body length: #{body.bytesize}")

        if body.include?("[mock:fail]")
          emit(block, type: "failed", error: "Mock agent simulated failure as requested")
          return 2
        end

        if spec && spec[:workspace_path]
          File.open(File.join(spec[:workspace_path], "quest_log.md"), "a") do |f|
            f.puts("## Instruction ##{seq}\n\n#{body}\n")
          end
        end

        summary = "Mock Agent completed instruction ##{seq}: #{body.lines.first.to_s.strip[0, 120]}"
        emit(block, type: "completed", summary: summary)
        0
      end

      def stop_container(container_id)
        @stopped_containers << container_id
      end

      def remove_container(container_id)
        return @on_remove.call(container_id) if @on_remove

        @removed_containers << container_id
        true
      end

      private
        def emit(block, **hash)
          block&.call("#{JSON.generate(hash)}\n", "stdout")
        end
    end
  end
end
