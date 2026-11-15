require "base64"
require "fileutils"
require "open3"

# Prepares a Quest's `/workspace` directory on the host before starting an
# Agent Container (Phase 8 / ADR 0012).
#
# Security invariants (docs/security.md):
# - GitHub App credentials and Installation Access Tokens stay on the host.
# - `git fetch` / `git clone` pass credentials via transient `http.extraHeader`
#   command-line options so `/workspace/.git/config` never contains a token.
module Omochi
  module GitHub
    class WorkspaceSyncer
      PR_DIFF_FILENAME = ".omochi_pr.diff".freeze
      GIT_TIMEOUT_SECONDS = 60

      def initialize(
        app_client: nil,
        remote_url_resolver: ->(repo) { "https://github.com/#{repo}.git" },
        command_runner: method(:default_run_git)
      )
        @app_client = app_client
        @remote_url_resolver = remote_url_resolver
        @command_runner = command_runner
      end

      def sync!(execution, workspace_dir)
        return nil unless enabled?

        repository = target_repository(execution)
        return nil if repository.blank?

        client = resolved_app_client
        installation_id = client.installation_id_for(repository)
        token = client.installation_token(installation_id)

        pr_resource = pull_request_resource(execution)
        if pr_resource
          sync_pull_request!(
            client: client,
            installation_id: installation_id,
            token: token,
            repository: repository,
            pull_number: pr_resource.external_id.to_s,
            workspace_dir: workspace_dir
          )
        else
          sync_default_branch!(
            token: token,
            repository: repository,
            quest_public_id: execution.quest.public_id,
            workspace_dir: workspace_dir
          )
        end
      rescue StandardError => e
        sanitized = sanitize_error_message(e.message)
        Rails.error.report(e, context: { execution_id: execution.id, sanitized_message: sanitized })
        nil
      end

      private
        def enabled?
          return true if @app_client.present?

          Omochi::Settings.dig(:github, :app_id).present? &&
            Omochi::Settings.dig(:github, :private_key).present?
        end

        def resolved_app_client
          @app_client || Omochi::GitHub.build_app_client
        end

        def target_repository(execution)
          gh_resource = github_resource_for(execution)
          return gh_resource.scope_key if gh_resource&.scope_key.present?

          Omochi::Settings.dig(:github, :repository).to_s.strip.presence
        end

        def pull_request_resource(execution)
          inst_res = execution.instruction.external_resource
          if inst_res&.platform == "github" && inst_res.resource_type == "pull_request"
            return inst_res
          end

          execution.quest.external_resources.find do |r|
            r.platform == "github" && r.resource_type == "pull_request"
          end
        end

        def github_resource_for(execution)
          inst_res = execution.instruction.external_resource
          return inst_res if inst_res&.platform == "github"

          execution.quest.external_resources.find { |r| r.platform == "github" }
        end

        def sync_pull_request!(client:, installation_id:, token:, repository:, pull_number:, workspace_dir:)
          pr_data = client.fetch_pull_request(
            installation_id: installation_id,
            repository: repository,
            pull_number: pull_number
          )
          diff_text = client.fetch_pull_request_diff(
            installation_id: installation_id,
            repository: repository,
            pull_number: pull_number
          )

          checked_out = false
          begin
            ensure_git_repo!(workspace_dir, repository)
            refspec = "+refs/pull/#{pull_number}/head:refs/remotes/origin/pr/#{pull_number}"
            run_authenticated_git(workspace_dir, token, "fetch", "--depth=50", "--no-tags", "origin", refspec)
            run_git(workspace_dir, "checkout", "-B", "omochi/pr-#{pull_number}", "-f", "refs/remotes/origin/pr/#{pull_number}")
            checked_out = true
          rescue StandardError => e
            Rails.logger.warn("[WorkspaceSyncer] Git checkout failed for #{repository}##{pull_number}: #{sanitize_error_message(e.message)}")
          end

          diff_path = File.join(workspace_dir.to_s, PR_DIFF_FILENAME)
          File.write(diff_path, diff_text.to_s)

          {
            "repository" => repository,
            "mode" => "pull_request",
            "pull_number" => pull_number.to_i,
            "title" => pr_data["title"].to_s,
            "base_ref" => pr_data.dig("base", "ref").to_s,
            "head_ref" => pr_data.dig("head", "ref").to_s,
            "head_sha" => pr_data.dig("head", "sha").to_s,
            "checked_out" => checked_out,
            "diff_file" => PR_DIFF_FILENAME
          }
        end

        def sync_default_branch!(token:, repository:, quest_public_id:, workspace_dir:)
          ensure_git_repo!(workspace_dir, repository)
          refspec = "+HEAD:refs/remotes/origin/default_head"
          run_authenticated_git(workspace_dir, token, "fetch", "--depth=50", "--no-tags", "origin", refspec)
          branch_name = "omochi/#{quest_public_id}"
          run_git(workspace_dir, "checkout", "-B", branch_name, "-f", "refs/remotes/origin/default_head")

          {
            "repository" => repository,
            "mode" => "branch",
            "branch" => branch_name,
            "checked_out" => true
          }
        end

        def ensure_git_repo!(workspace_dir, repository)
          dir = workspace_dir.to_s
          FileUtils.mkdir_p(dir)
          remote_url = @remote_url_resolver.call(repository)

          unless File.directory?(File.join(dir, ".git"))
            run_git(dir, "init")
          end

          remotes_out = run_git(dir, "remote")
          if remotes_out.lines.map(&:strip).include?("origin")
            run_git(dir, "remote", "set-url", "origin", remote_url)
          else
            run_git(dir, "remote", "add", "origin", remote_url)
          end
        end

        def run_authenticated_git(workspace_dir, token, *args)
          basic = Base64.strict_encode64("x-access-token:#{token}")
          header = "Authorization: basic #{basic}"
          run_git(workspace_dir, "-c", "http.extraHeader=#{header}", *args)
        end

        def run_git(workspace_dir, *args)
          @command_runner.call(workspace_dir.to_s, args)
        end

        def default_run_git(workspace_dir, args)
          env = { "GIT_TERMINAL_PROMPT" => "0" }
          cmd = [ "git", "-C", workspace_dir, *args ]
          stdout, stderr, status = Open3.capture3(env, *cmd)
          unless status.success?
            raise Error, "git command failed (exit #{status.exitstatus}): #{sanitize_error_message(stderr.presence || stdout)}"
          end

          stdout
        end

        def sanitize_error_message(msg)
          msg.to_s
            .gsub(/Authorization:\s*basic\s+[A-Za-z0-9+\/=]+/i, "Authorization: basic [REDACTED]")
            .gsub(/x-access-token:[^\s@]+/i, "x-access-token:[REDACTED]")
            .gsub(/ghs_[A-Za-z0-9_]+/, "[REDACTED]")
        end
    end
  end
end
