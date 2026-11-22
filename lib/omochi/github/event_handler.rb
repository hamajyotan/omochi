# Processes incoming GitHub Webhook events.
#
# Handled events:
# 1. `pull_request`:
#    - `action: "review_requested"`: when reviewer requested is `omochi` (or configured slug),
#      starts a new Quest or attaches to an existing Quest for this PR.
#    - `action: "synchronize"`: new commits pushed to the PR; queues a re-review if a Quest exists.
# 2. `issue_comment`:
#    - `action: "created"`: follow-up comment on an existing Quest PR or Issue.
module Omochi
  module GitHub
    class EventHandler
      Result = Data.define(:status, :instruction, :created_quest, :duplicate)

      def handle(event_type:, delivery_id:, payload:)
        return ignored unless payload.is_a?(Hash)
        return ignored unless allowed_repository?(payload["repository"])

        case event_type
        when "pull_request"
          handle_pull_request(delivery_id, payload)
        when "issue_comment"
          handle_issue_comment(delivery_id, payload)
        else
          ignored
        end
      end

      private
        def ignored
          Result.new(status: :ignored, instruction: nil, created_quest: false, duplicate: false)
        end

        def allowed_repository?(repo)
          return false unless repo.is_a?(Hash)

          full_name = repo["full_name"].to_s.strip
          return false if full_name.empty?

          configured_repositories.any? { |r| r.casecmp?(full_name) }
        end

        def configured_repositories
          raw = Omochi::Settings.dig(:github, :repositories).to_s
          default_repo = Omochi::Settings.dig(:github, :repository).to_s.strip
          list = raw.split(",").map(&:strip).reject(&:empty?)
          list << default_repo if default_repo.present?
          list.uniq
        end

        def handle_pull_request(delivery_id, payload)
          action = payload["action"]
          pr = payload["pull_request"]
          repo = payload["repository"]
          return ignored unless pr.is_a?(Hash) && repo.is_a?(Hash)

          case action
          when "review_requested"
            requested_reviewer = payload["requested_reviewer"]
            return ignored unless reviewer_is_omochi?(requested_reviewer)

            process_pr_review_request(delivery_id, pr, repo)
          when "opened", "reopened"
            return ignored if payload.dig("sender", "type") == "Bot"
            return ignored unless has_slash_command?(pr["body"])

            process_pr_review_request(delivery_id, pr, repo)
          when "synchronize"
            return ignored if payload.dig("sender", "type") == "Bot"

            process_pr_synchronize(delivery_id, pr, repo)
          else
            ignored
          end
        end

        def reviewer_is_omochi?(requested_reviewer)
          return false unless requested_reviewer.is_a?(Hash)

          configured_slug = (Omochi::Settings.dig(:github, :app_slug) || "omochi").to_s
          login = requested_reviewer["login"].to_s.sub(/\[bot\]\z/, "")
          login.casecmp?(configured_slug) || login.casecmp?("omochi") || login.casecmp?("omochi-agent")
        end

        SLASH_COMMAND_PATTERN = /(?:\A|\s|[^\w])\/(?:review|omochi)\b/i

        def has_slash_command?(text)
          return false if text.blank?

          text.match?(SLASH_COMMAND_PATTERN)
        end

        def has_omochi_label?(issue)
          labels = issue["labels"]
          return false unless labels.is_a?(Array)

          labels.any? { |label| label.is_a?(Hash) && label["name"].to_s.casecmp?("omochi") }
        end

        def process_pr_review_request(delivery_id, pr, repo)
          existing = QuestInstruction.find_duplicate(source_platform: "github", source_event_id: delivery_id)
          return Result.new(status: :duplicate, instruction: existing, created_quest: false, duplicate: true) if existing

          scope_key = repo["full_name"].to_s
          pr_number = pr["number"].to_s
          resource = ExternalResource.identity(
            platform: "github",
            resource_type: "pull_request",
            scope_key: scope_key,
            external_id: pr_number
          )

          instruction_body = build_pr_instruction_body(pr, action_label: "review requested")

          if resource
            instruction = resource.quest.receive_instruction!(
              body: instruction_body,
              source_platform: "github",
              source_event_id: delivery_id,
              external_resource: resource
            )
            Result.new(status: :accepted, instruction: instruction, created_quest: false, duplicate: false)
          else
            title = "Review PR ##{pr_number}: #{pr['title'].to_s.truncate(80)}"
            instruction = Quest.start!(
              title: title,
              body: instruction_body,
              source_platform: "github",
              source_event_id: delivery_id,
              external_resource: {
                platform: "github",
                resource_type: "pull_request",
                scope_key: scope_key,
                external_id: pr_number,
                url: pr["html_url"].to_s
              }
            )
            Result.new(status: :accepted, instruction: instruction, created_quest: true, duplicate: false)
          end
        rescue ActiveRecord::RecordNotUnique
          existing = QuestInstruction.find_duplicate(source_platform: "github", source_event_id: delivery_id)
          Result.new(status: :duplicate, instruction: existing, created_quest: false, duplicate: true)
        end

        def process_pr_synchronize(delivery_id, pr, repo)
          scope_key = repo["full_name"].to_s
          pr_number = pr["number"].to_s
          resource = ExternalResource.identity(
            platform: "github",
            resource_type: "pull_request",
            scope_key: scope_key,
            external_id: pr_number
          )
          return ignored unless resource # Only re-review if a Quest already exists for this PR

          instruction_body = "New commits were pushed to PR ##{pr_number}. Please perform a follow-up review.\nHead SHA: #{pr.dig('head', 'sha')}"
          instruction = resource.quest.receive_instruction!(
            body: instruction_body,
            source_platform: "github",
            source_event_id: delivery_id,
            external_resource: resource
          )
          Result.new(status: :accepted, instruction: instruction, created_quest: false, duplicate: false)
        rescue ActiveRecord::RecordNotUnique
          existing = QuestInstruction.find_duplicate(source_platform: "github", source_event_id: delivery_id)
          Result.new(status: :duplicate, instruction: existing, created_quest: false, duplicate: true)
        end

        def handle_issue_comment(delivery_id, payload)
          return ignored unless payload["action"] == "created"

          comment = payload["comment"]
          issue = payload["issue"]
          repo = payload["repository"]
          return ignored unless comment.is_a?(Hash) && issue.is_a?(Hash) && repo.is_a?(Hash)
          return ignored if comment.dig("user", "type") == "Bot" || comment.dig("user", "login").to_s.end_with?("[bot]")

          scope_key = repo["full_name"].to_s
          issue_number = issue["number"].to_s
          resource_type = issue.key?("pull_request") ? "pull_request" : "issue"

          resource = ExternalResource.identity(
            platform: "github",
            resource_type: resource_type,
            scope_key: scope_key,
            external_id: issue_number
          )
          body = comment["body"].to_s.strip
          return ignored if body.empty?
          return ignored unless has_slash_command?(body) || (resource_type == "pull_request" && has_omochi_label?(issue))

          if resource
            instruction = resource.quest.receive_instruction!(
              body: body,
              source_platform: "github",
              source_event_id: delivery_id,
              external_resource: resource
            )
            Result.new(status: :accepted, instruction: instruction, created_quest: false, duplicate: false)
          else
            existing = QuestInstruction.find_duplicate(source_platform: "github", source_event_id: delivery_id)
            return Result.new(status: :duplicate, instruction: existing, created_quest: false, duplicate: true) if existing

            prefix = resource_type == "pull_request" ? "Review PR" : "Issue"
            title = "#{prefix} ##{issue_number}: #{issue['title'].to_s.truncate(80)}"
            instruction_body = build_issue_comment_instruction_body(comment, issue, resource_type: resource_type)

            instruction = Quest.start!(
              title: title,
              body: instruction_body,
              source_platform: "github",
              source_event_id: delivery_id,
              external_resource: {
                platform: "github",
                resource_type: resource_type,
                scope_key: scope_key,
                external_id: issue_number,
                url: issue["html_url"].to_s
              }
            )
            Result.new(status: :accepted, instruction: instruction, created_quest: true, duplicate: false)
          end
        rescue ActiveRecord::RecordNotUnique
          existing = QuestInstruction.find_duplicate(source_platform: "github", source_event_id: delivery_id)
          Result.new(status: :duplicate, instruction: existing, created_quest: false, duplicate: true)
        end

        def build_issue_comment_instruction_body(comment, issue, resource_type:)
          user_login = comment.dig("user", "login")
          body = comment["body"].to_s.strip

          if resource_type == "pull_request"
            <<~BODY.strip
              Pull Request review requested via comment: ##{issue['number']} - #{issue['title']}
              URL: #{issue['html_url']}
              Comment by @#{user_login}:
              #{body}

              PR Description:
              #{issue['body'].presence || '(no description)'}
            BODY
          else
            <<~BODY.strip
              GitHub Issue ##{issue['number']} - #{issue['title']}
              URL: #{issue['html_url']}
              Comment by @#{user_login}:
              #{body}

              Issue Description:
              #{issue['body'].presence || '(no description)'}
            BODY
          end
        end

        def build_pr_instruction_body(pr, action_label:)
          <<~BODY.strip
            Pull Request #{action_label}: ##{pr['number']} - #{pr['title']}
            URL: #{pr['html_url']}
            Author: #{pr.dig('user', 'login')}
            Base: #{pr.dig('base', 'ref')} <- Head: #{pr.dig('head', 'ref')} (#{pr.dig('head', 'sha')})

            Description:
            #{pr['body'].presence || '(no description)'}
          BODY
        end
    end
  end
end
