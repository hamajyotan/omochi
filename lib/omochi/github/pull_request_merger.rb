# Merges a Pull Request via the GitHub App API when a user issues `/merge`
# in a Quest thread (without spinning up an Agent Container).
module Omochi
  module GitHub
    class PullRequestMerger
      class MergeError < StandardError; end

      VALID_METHODS = %w[merge squash rebase].freeze
      PR_URL_PATTERN = %r{\Ahttps://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/(\d+)\z}i

      def self.parse_command(body)
        tokens = body.to_s.strip.split(/\s+/)
        return nil unless tokens.first&.casecmp?("/merge")

        merge_method = "merge"
        pr_url = nil
        repository = nil
        pull_number = nil

        tokens[1..].each do |arg|
          if VALID_METHODS.include?(arg.downcase)
            merge_method = arg.downcase
          elsif (match = arg.match(PR_URL_PATTERN))
            pr_url = arg
            repository = match[1]
            pull_number = match[2].to_i
          else
            return nil
          end
        end

        {
          merge_method: merge_method,
          pr_url: pr_url,
          repository: repository,
          pull_number: pull_number
        }
      end

      def self.merge_command?(body)
        !parse_command(body).nil?
      end

      def initialize(app_client: nil)
        @app_client = app_client
      end

      def merge!(execution)
        parsed = self.class.parse_command(execution.instruction.body)
        raise MergeError, "Invalid /merge command." unless parsed

        raise MergeError, "GitHub App is not configured." unless enabled?

        repository, pull_number, pr_url = resolve_target_pr(execution, parsed)
        merge_method = parsed[:merge_method]

        client = resolved_app_client
        installation_id = client.installation_id_for(repository)
        response = client.merge_pull_request(
          installation_id: installation_id,
          repository: repository,
          pull_number: pull_number,
          merge_method: merge_method
        )

        unless response["merged"]
          raise MergeError, response["message"].presence || "Pull Request ##{pull_number} could not be merged."
        end

        {
          "repository" => repository,
          "pull_number" => pull_number,
          "merge_method" => merge_method,
          "sha" => response["sha"],
          "url" => pr_url
        }
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

        def resolve_target_pr(execution, parsed)
          if parsed[:repository].present? && parsed[:pull_number].present?
            matched_repo = configured_repositories.find { |r| r.casecmp?(parsed[:repository]) }
            raise MergeError, "Repository #{parsed[:repository]} is not in GITHUB_REPOSITORIES." unless matched_repo

            return [ matched_repo, parsed[:pull_number], parsed[:pr_url] ]
          end

          resource =
            execution.instruction.external_resource&.then do |res|
              res if res.platform == "github" && res.resource_type == "pull_request"
            end ||
            execution.quest.external_resources
              .where(platform: "github", resource_type: "pull_request")
              .order(id: :desc)
              .first

          if resource.nil?
            raise MergeError, "マージ対象の Pull Request が見つかりません。PR 作成済みのスレッドで `/merge` を実行するか、`/merge <PR_URL>` を指定してください。"
          end

          repository = resource.scope_key.to_s
          pull_number = resource.external_id.to_i
          pr_url = resource.url.presence || "https://github.com/#{repository}/pull/#{pull_number}"
          [ repository, pull_number, pr_url ]
        end

        def configured_repositories
          raw = Omochi::Settings.dig(:github, :repositories).to_s
          default_repo = Omochi::Settings.dig(:github, :repository).to_s.strip
          repos = raw.split(",").map(&:strip).reject(&:empty?)
          repos << default_repo if default_repo.present? && !repos.include?(default_repo)
          repos
        end
    end
  end
end
