require "open3"

# Adapter around the `docker` CLI.
#
# All invocations pass an argument Array directly to `Open3` (`[docker_bin, ...]`):
# no shell is ever spawned, and no host credentials or Docker socket are mounted
# into the Agent Container.
module Omochi
  module Docker
    class CliClient
      CONTAINER_AGENT_PATH = "/opt/omochi/agent_runner".freeze
      CONTAINER_WORKSPACE_PATH = "/workspace".freeze

      def initialize(docker_bin: "docker", capture3: Open3.method(:capture3))
        @docker_bin = docker_bin
        @capture3 = capture3
      end

      # Creates an isolated Agent Container and returns its container ID.
      def create_container(name:, image:, workspace_path:, agent_script_path:, memory:, cpus:, pids_limit:, command: nil, network: "none", env: {})
        args = build_create_args(
          name:, image:, workspace_path:, agent_script_path:, memory:, cpus:, pids_limit:, command:, network:, env:
        )

        stdout, stderr, status = @capture3.call(*args, unsetenv_others: false)
        raise Error, "docker create failed (exit #{status.exitstatus}): #{stderr.strip}" unless status.success?

        container_id = stdout.strip
        raise Error, "docker create returned an empty container ID" if container_id.empty?

        container_id
      rescue Errno::ENOENT => e
        raise Error, "docker CLI not found: #{e.message}"
      end

      def build_create_args(name:, image:, workspace_path:, agent_script_path:, memory:, cpus:, pids_limit:, command: nil, network: "none", env: {})
        cmd = command.presence || [ "ruby", CONTAINER_AGENT_PATH ]
        args = [
          @docker_bin, "create",
          "--name", name.to_s,
          "--network", network.to_s,
          "--read-only",
          "--tmpfs", "/tmp:rw,nosuid,mode=1777,size=256m",
          "--tmpfs", "/home/agent:rw,nosuid,mode=1777,size=256m",
          "--cap-drop", "ALL",
          "--security-opt", "no-new-privileges",
          "--memory", memory.to_s,
          "--cpus", cpus.to_s,
          "--pids-limit", pids_limit.to_s,
          "--user", "#{Process.uid}:#{Process.gid}",
          "--volume", "#{workspace_path}:#{CONTAINER_WORKSPACE_PATH}:rw",
          "--volume", "#{agent_script_path}:#{CONTAINER_AGENT_PATH}:ro",
          "--workdir", CONTAINER_WORKSPACE_PATH
        ]

        merged_env = { "HOME" => "/home/agent" }.merge(env)
        merged_env.each do |key, value|
          args.push("--env", "#{key}=#{value}")
        end

        args.push(image.to_s, *cmd)
        args
      end

      # Starts the created container attached, yields each line of output with
      # its stream ("stdout" / "stderr"), and returns the integer exit status.
      # Raises TimeoutError after forcibly stopping the container if
      # `timeout_seconds` elapses.
      def run_attached(container_id, timeout_seconds:, on_heartbeat: nil)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds.to_f
        timed_out = false

        Open3.popen3(@docker_bin, "start", "--attach", container_id.to_s) do |stdin, stdout, stderr, wait_thr|
          stdin.close
          open_ios = [ stdout, stderr ]
          buffers = { stdout => +"", stderr => +"" }

          until open_ios.empty?
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            if remaining <= 0
              timed_out = true
              stop_container(container_id)
              break
            end

            ready = IO.select(open_ios, nil, nil, [ remaining, 1.0 ].min)
            on_heartbeat&.call

            next unless ready

            ready[0].each do |io|
              stream_name = io == stdout ? "stdout" : "stderr"
              chunk = io.read_nonblock(4096, exception: false)
              case chunk
              when :wait_readable
                next
              when nil
                unless buffers[io].empty?
                  yield(buffers[io], stream_name) if block_given?
                  buffers[io].clear
                end
                open_ios.delete(io)
              else
                buffers[io] << chunk
                while (newline_idx = buffers[io].index("\n"))
                  line = buffers[io].slice!(0..newline_idx)
                  yield(line, stream_name) if block_given?
                end
              end
            end
          end

          status = wait_thr.value
          raise TimeoutError, "Container #{container_id} timed out after #{timeout_seconds}s" if timed_out

          status.exitstatus || 1
        end
      rescue Errno::ENOENT => e
        raise Error, "docker CLI not found: #{e.message}"
      end

      def stop_container(container_id)
        @capture3.call(@docker_bin, "kill", container_id.to_s)
      rescue StandardError
        nil
      end

      # Removes the container forcibly. Treats "No such container" as already
      # removed so cleanup is idempotent.
      def remove_container(container_id)
        _stdout, stderr, status = @capture3.call(@docker_bin, "rm", "--force", "--volumes", container_id.to_s)
        return true if status.success? || stderr.include?("No such container")

        raise Error, "docker rm failed (exit #{status.exitstatus}): #{stderr.strip}"
      rescue Errno::ENOENT => e
        raise Error, "docker CLI not found: #{e.message}"
      end
    end
  end
end
